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
      members: :auto,
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
