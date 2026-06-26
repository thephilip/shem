defmodule Shem.Cluster do
  use GenServer
  require Logger

  @system_session "sys:cluster"

  # ── Client API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Graceful shutdown (incl. `shem stop` → init:stop) runs terminate/2 → evacuate_all/0.
  # Give it room to flush checkpoints + hand off agents before OTP brutal-kills it.
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 30_000}
  end

  @spec members() :: [node()]
  def members, do: [Node.self() | Node.list()]

  # kept for backward compatibility
  @spec nodes() :: [node()]
  def nodes, do: members()

  @spec agent_count(node()) :: non_neg_integer()
  def agent_count(target_node) do
    try do
      Horde.DynamicSupervisor.which_children(Shem.AgentSupervisor)
      |> Enum.count(fn {_, pid, _, _} ->
        is_pid(pid) && node(pid) == target_node
      end)
    catch
      _, _ -> 0
    end
  end

  # ── Server callbacks ────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    if Application.get_env(:shem, :start_cluster, true) && !Node.alive?() do
      Logger.warning(
        "Shem: start_cluster is true but this node has no name. " <>
          "Start with --sname or --name to enable clustering."
      )
    end

    Process.flag(:trap_exit, true)
    :net_kernel.monitor_nodes(true)
    # Bootstrap Horde membership with currently connected nodes (no NodeListener).
    send(self(), :bootstrap_horde)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:bootstrap_horde, state) do
    sync_horde(Node.self())
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("Shem.Cluster: node joined — #{node}")
    emit(:cluster_node_joined, %{node: node})
    sync_horde(node)
    onboard_mnesia(node)
    Shem.NodeRegistry.sync_node(node)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.info("Shem.Cluster: node left — #{node}")
    emit(:cluster_node_left, %{node: node})
    Shem.NodeRegistry.remove_node(node)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    Logger.info("Shem.Cluster: graceful shutdown — evacuating agents")

    try do
      Shem.AgentSupervisor.evacuate_all()
    catch
      kind, reason ->
        Logger.warning(
          "Shem.Cluster: evacuation error during shutdown: #{kind} #{inspect(reason)}"
        )
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp emit(type, payload) do
    try do
      Shem.EventLog.append(@system_session, type, payload)
    catch
      _, _ -> :ok
    end
  end

  defp onboard_mnesia(existing_node) do
    try do
      Shem.EventLog.MnesiaStore.onboard_from(existing_node)
    catch
      _, reason ->
        Logger.warning(
          "Shem.Cluster: Mnesia onboarding failed for #{existing_node}: #{inspect(reason)}"
        )
    end
  end

  defp sync_horde(new_node) do
    all_nodes = [Node.self() | Node.list()]
    members = Enum.map(all_nodes, &{Shem.AgentSupervisor, &1})
    reg_members = Enum.map(all_nodes, &{Shem.Registry, &1})

    try do
      Horde.Cluster.set_members(Shem.AgentSupervisor, members)
      Horde.Cluster.set_members(Shem.Registry, reg_members)
    catch
      _, reason ->
        Logger.warning("Shem.Cluster: Horde sync failed for #{new_node}: #{inspect(reason)}")
    end
  end
end
