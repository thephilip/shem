defmodule Shem.NodeRegistry do
  @moduledoc """
  ETS-backed registry of node capability labels.

  Each node publishes a map of string key-value labels (e.g. `%{"model" => "llama3"}`).
  Labels are ephemeral — entries are removed on `:nodedown` so stale data never accumulates.

  Placement resolution queries `nodes_matching/1` to find nodes whose label map is a
  superset of a requested selector.

  All reads go through GenServer calls (no named ETS table) so multiple registry instances
  can coexist in test environments without naming conflicts.
  """
  use GenServer

  require Logger

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  # ── Client API (server: pid or name, defaults to __MODULE__) ─────────────────

  @spec labels(GenServer.server(), node()) :: %{String.t() => String.t()}
  def labels(server \\ __MODULE__, node) do
    GenServer.call(server, {:labels, node})
  end

  @spec nodes_matching(GenServer.server(), %{String.t() => String.t()}) :: [node()]
  def nodes_matching(server \\ __MODULE__, selector) when is_map(selector) do
    GenServer.call(server, {:nodes_matching, selector})
  end

  @spec set_labels(GenServer.server(), %{String.t() => String.t()}) :: :ok
  def set_labels(server \\ __MODULE__, labels) when is_map(labels) do
    :ok = GenServer.call(server, {:put_node, Node.self(), labels})
    Enum.each(Node.list(), fn peer ->
      :rpc.cast(peer, __MODULE__, :put_node, [Node.self(), labels])
    end)
    :ok
  end

  @spec put_node(GenServer.server(), node(), %{String.t() => String.t()}) :: :ok
  def put_node(server \\ __MODULE__, node, labels) when is_map(labels) do
    GenServer.call(server, {:put_node, node, labels})
  end

  @spec remove_node(GenServer.server(), node()) :: :ok
  def remove_node(server \\ __MODULE__, node) do
    GenServer.call(server, {:remove_node, node})
  end

  @spec sync_node(GenServer.server(), node()) :: :ok
  def sync_node(server \\ __MODULE__, node) do
    GenServer.cast(server, {:sync_node, node})
  end

  @spec all(GenServer.server()) :: %{node() => %{String.t() => String.t()}}
  def all(server \\ __MODULE__) do
    GenServer.call(server, :all)
  end

  # ── Server ────────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(:node_labels, [:set, :protected])
    own_labels = Application.get_env(:shem, :node_labels, %{})
    :ets.insert(table, {Node.self(), own_labels})
    Enum.each(Node.list(), &do_sync_node(table, &1))
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:labels, node}, _from, %{table: table} = state) do
    result =
      case :ets.lookup(table, node) do
        [{^node, labels}] -> labels
        [] -> %{}
      end
    {:reply, result, state}
  end

  def handle_call({:nodes_matching, selector}, _from, %{table: table} = state) do
    result =
      :ets.tab2list(table)
      |> Enum.filter(fn {_node, labels} ->
        Enum.all?(selector, fn {k, v} -> Map.get(labels, k) == v end)
      end)
      |> Enum.map(fn {node, _} -> node end)
    {:reply, result, state}
  end

  def handle_call({:put_node, node, labels}, _from, %{table: table} = state) do
    :ets.insert(table, {node, labels})
    {:reply, :ok, state}
  end

  def handle_call({:remove_node, node}, _from, %{table: table} = state) do
    :ets.delete(table, node)
    {:reply, :ok, state}
  end

  def handle_call(:all, _from, %{table: table} = state) do
    result = :ets.tab2list(table) |> Map.new()
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:sync_node, node}, %{table: table} = state) do
    do_sync_node(table, node)
    {:noreply, state}
  end

  defp do_sync_node(table, node) do
    case :rpc.call(node, Application, :get_env, [:shem, :node_labels, %{}]) do
      {:badrpc, reason} ->
        Logger.debug("NodeRegistry: could not sync #{node}: #{inspect(reason)}")

      labels when is_map(labels) ->
        :ets.insert(table, {node, labels})

      _ ->
        :ok
    end
  end
end
