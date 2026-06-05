defmodule Shem.Cluster do
  use GenServer

  # ── Client API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec nodes() :: [node()]
  def nodes, do: [Node.self() | Node.list()]

  # ── Server callbacks ────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :net_kernel.monitor_nodes(true)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodeup, _node}, state), do: {:noreply, state}

  @impl true
  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
