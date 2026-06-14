defmodule Shem.AgentSupervisor do
  use Horde.DynamicSupervisor

  alias Shem.Agent.Config

  def start_link(init_arg) do
    Horde.DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    Horde.DynamicSupervisor.init(
      strategy: :one_for_one,
      members: [{__MODULE__, Node.self()}],
      distribution_strategy: Shem.PlacementStrategy
    )
  end

  @spec start_agent(String.t(), Config.t()) :: {:ok, pid(), String.t()} | {:error, term()}
  def start_agent(name, %Config{} = config) do
    session_id = generate_session_id()

    case resolve_placement(config.placement) do
      {:error, reason} ->
        {:error, reason}

      {:ok, resolved, miss_selector} ->
        case start_agent_with_placement(name, config, session_id, resolved) do
          {:ok, pid} ->
            if miss_selector do
              Shem.EventLog.append(session_id, :placement_miss, %{
                requested: miss_selector,
                landed_on: Node.self()
              })
            end

            maybe_start_shadow(name, session_id, pid)
            {:ok, pid, session_id}

          error ->
            error
        end
    end
  end

  @spec start_agent(String.t(), Config.t(), String.t()) :: Horde.DynamicSupervisor.on_start_child()
  def start_agent(name, %Config{} = config, session_id) do
    via = via_with_meta(name, session_id, config.placement, nil)

    child_spec = %{
      id: name,
      start: {Shem.Agent.Server, :start_link, [{name, config, session_id, [name: via]}]},
      restart: :transient
    }

    case Horde.DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} = result ->
        maybe_start_shadow(name, session_id, pid)
        result

      error ->
        error
    end
  end

  defp start_agent_with_placement(name, config, session_id, resolved) do
    target_node = case resolved do
      :any -> nil
      {:node, n} -> n
    end

    via = via_with_meta(name, session_id, config.placement, target_node)

    child_spec = %{
      id: name,
      start: {Shem.Agent.Server, :start_link, [{name, config, session_id, [name: via]}]},
      restart: :transient,
      placement_node: target_node
    }

    Horde.DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  defp via_with_meta(name, session_id, placement, resolved_node) do
    Shem.ProcessRegistry.via_tuple_with_meta(name, session_id, %{
      placement: placement,
      resolved_node: resolved_node
    })
  end

  defp resolve_placement(:any), do: {:ok, :any, nil}

  defp resolve_placement({:node, n}) do
    if n == Node.self() || n in Node.list() do
      {:ok, {:node, n}, nil}
    else
      {:error, :no_matching_node}
    end
  end

  defp resolve_placement({:labels, selector}) do
    case Shem.NodeRegistry.nodes_matching(selector) do
      [] -> {:ok, :any, selector}
      nodes -> {:ok, {:node, Enum.random(nodes)}, nil}
    end
  end

  defp resolve_placement({:labels, selector, :required}) do
    case Shem.NodeRegistry.nodes_matching(selector) do
      [] -> {:error, :no_matching_node}
      nodes -> {:ok, {:node, Enum.random(nodes)}, nil}
    end
  end

  @doc """
  Flushes checkpoints for all agents running on this node and pushes each to a
  surviving peer node. Called by Shem.Cluster.terminate/2 on graceful shutdown.
  """
  @spec evacuate_all() :: :ok
  def evacuate_all do
    timeout = Application.get_env(:shem, :evacuation_timeout_ms, 5_000)

    local_agents =
      Horde.DynamicSupervisor.which_children(__MODULE__)
      |> Enum.filter(fn {_, pid, _, _} -> is_pid(pid) && node(pid) == Node.self() end)

    Task.async_stream(
      local_agents,
      fn {_, pid, _, _} -> evacuate_agent(pid, timeout) end,
      timeout: timeout + 1_000,
      on_timeout: :kill_task
    )
    |> Stream.run()

    :ok
  end

  defp evacuate_agent(pid, timeout) do
    require Logger

    # Step 1: get agent identity
    {name, config, session_id} =
      try do
        GenServer.call(pid, :evac_spec, timeout)
      catch
        :exit, _ ->
          Logger.warning("AgentSupervisor: evac_spec timed out for #{inspect(pid)}")
          {nil, nil, nil}
      end

    if is_nil(session_id) do
      :skip
    else
      # Step 2: flush checkpoint
      try do
        GenServer.call(pid, :flush_checkpoint, timeout)
      catch
        :exit, _ ->
          Logger.warning("AgentSupervisor: flush_checkpoint timed out for session #{session_id}")
      end

      # Step 3: find a target survivor
      survivors = Node.list()
      self_node = Node.self()

      target_node =
        if survivors == [] do
          nil
        else
          case config.placement do
            {:labels, selector} ->
              matches =
                Shem.NodeRegistry.nodes_matching(selector) |> Enum.reject(&(&1 == self_node))

              if matches != [], do: Enum.random(matches), else: Enum.random(survivors)

            {:labels, selector, _} ->
              matches =
                Shem.NodeRegistry.nodes_matching(selector) |> Enum.reject(&(&1 == self_node))

              if matches != [], do: Enum.random(matches), else: Enum.random(survivors)

            {:node, n} when n != :nonode@nohost ->
              if n != self_node && n in survivors, do: n, else: Enum.random(survivors)

            _ ->
              Enum.random(survivors)
          end
        end

      # Step 4: terminate the local copy first so the child id is removed from
      # Horde's CRDT before we start_child on the target.  If we start first,
      # Horde sees the id already in the CRDT and returns {:already_started}.
      Horde.DynamicSupervisor.terminate_child(__MODULE__, pid)

      # Step 5: push to target (if available)
      if target_node do
        via = via_with_meta(name, session_id, config.placement, target_node)

        child_spec = %{
          id: name,
          start: {Shem.Agent.Server, :start_link, [{name, config, session_id, [name: via]}]},
          restart: :transient,
          placement_node: target_node
        }

        case Horde.DynamicSupervisor.start_child(__MODULE__, child_spec) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "AgentSupervisor: evacuation failed for session #{session_id}: #{inspect(reason)}"
            )

            Shem.EventLog.append(session_id, :evacuation_failed, %{reason: inspect(reason)})
        end
      else
        Logger.warning(
          "AgentSupervisor: no surviving nodes for evacuation of session #{session_id}; " <>
            "checkpoint preserved in Mnesia"
        )
      end
    end
  end

  defp maybe_start_shadow(agent_name, session_id, agent_pid) do
    if Application.get_env(:shem, :shadow_agent_enabled, true) &&
         Process.whereis(Shem.Shadow.Supervisor) do
      shadow_spec = %{
        id: "shadow_#{agent_name}",
        start: {Shem.Shadow.Agent, :start_link, [{agent_name, session_id, agent_pid}]},
        restart: :temporary
      }

      DynamicSupervisor.start_child(Shem.Shadow.Supervisor, shadow_spec)
    end

    :ok
  end

  defp generate_session_id do
    "ses_" <> Base.encode16(:crypto.strong_rand_bytes(8))
  end
end
