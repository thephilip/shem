# Phase 40 — Agent Failover, Evacuation & Placement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make agents survive node death transparently, shut down gracefully without losing progress, and start on capability-matched nodes via a dynamic label registry.

**Architecture:** Four capabilities built in sequence — crash recovery via `:transient` Horde restarts + Mnesia checkpoints; a `Shem.NodeRegistry` ETS-backed capability registry; placement hints in `Agent.Config` resolved by a custom `Shem.PlacementStrategy`; and graceful SIGTERM evacuation via push-handoff in `AgentSupervisor.evacuate_all/0`. Each task is independently testable and committed.

**Tech Stack:** Elixir, OTP GenServer + ETS, Horde DynamicSupervisor + DistributionStrategy, ExUnit `:peer` for distributed tests.

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `lib/shem/placement_strategy.ex` | Horde.DistributionStrategy: routes agents to pinned nodes |
| Create | `lib/shem/node_registry.ex` | ETS-backed label store: own labels + cluster sync |
| Modify | `lib/shem/agent.ex` | Add `placement` field to `Agent.Config` |
| Modify | `lib/shem/agent/checkpoint.ex` | Add `node` field to saved payload |
| Modify | `lib/shem/agent/server.ex` | Add `:flush_checkpoint` + `:evac_spec` handlers; update `:agent_resumed` |
| Modify | `lib/shem/agent_supervisor.ex` | `:transient` restart, `PlacementStrategy`, `resolve_placement/1`, `evacuate_all/0` |
| Modify | `lib/shem/process_registry.ex` | Store placement metadata alongside session_id |
| Modify | `lib/shem/cluster.ex` | Trap exits, `terminate/2`, call `NodeRegistry` on node events |
| Modify | `lib/shem/application.ex` | Add `Shem.NodeRegistry` to supervision tree |
| Modify | `test/shem/agent/checkpoint_test.exs` | Add `node` field assertions |
| Modify | `test/shem/agent_supervisor_test.exs` | Update restart test, add placement + evacuation tests |
| Modify | `test/shem/cluster_test.exs` | Add NodeRegistry sync + SIGTERM tests |
| Create | `test/shem/node_registry_test.exs` | NodeRegistry unit tests |
| Create | `test/shem/distributed/failover_test.exs` | `:peer` tests for crash recovery + evacuation |

---

## Task 1: Checkpoint Node Field + agent_resumed prior_node

**Files:**
- Modify: `lib/shem/agent/checkpoint.ex`
- Modify: `lib/shem/agent/server.ex` (lines 95–100)
- Modify: `test/shem/agent/checkpoint_test.exs`

- [ ] **Step 1.1: Write the failing tests**

In `test/shem/agent/checkpoint_test.exs`, add inside `describe "save/2"`:

```elixir
test "checkpoint payload contains node field" do
  id = open_session("ses_CKPT_NODE_#{System.unique_integer([:positive])}")
  state = make_state()
  Checkpoint.save(id, state)
  {:ok, events} = EventLog.events(id)
  event = Enum.find(events, &(&1.type == :agent_checkpoint))
  assert Map.has_key?(event.payload, :node)
  assert event.payload.node == Node.self()
end
```

And add inside `describe "reconstruct/1"`:

```elixir
test "reconstructed checkpoint includes node field" do
  id = open_session("ses_CKPT_NODE_RT_#{System.unique_integer([:positive])}")
  Checkpoint.save(id, make_state())
  {:ok, checkpoint} = Checkpoint.reconstruct(id)
  assert checkpoint.node == Node.self()
end
```

- [ ] **Step 1.2: Run to confirm failure**

```bash
cd /home/philip/Downloads/_project/shem
mix test test/shem/agent/checkpoint_test.exs 2>&1 | tail -15
```

Expected: 2 failures — `node` key missing from payload.

- [ ] **Step 1.3: Update Checkpoint.save/2**

In `lib/shem/agent/checkpoint.ex`, replace the `save/2` function body:

```elixir
@spec save(String.t(), map()) :: :ok | {:error, term()}
def save(session_id, state) do
  case EventLog.append(session_id, :agent_checkpoint, %{
         history: state.history,
         turn_count: state.turn_count,
         config: state.config,
         node: Node.self()
       }) do
    {:ok, _} -> :ok
    {:error, reason} -> {:error, reason}
  end
end
```

- [ ] **Step 1.4: Update Agent.Server.init/1 resume branch**

In `lib/shem/agent/server.ex`, replace lines 95–100 (the `{:ok, checkpoint}` branch of `Checkpoint.reconstruct`):

```elixir
{:ok, checkpoint} ->
  EventLog.append(session_id, :agent_resumed, %{
    node: Node.self(),
    prior_node: Map.get(checkpoint, :node),
    turn: checkpoint.turn_count
  })
  {checkpoint.history, checkpoint.turn_count}
```

- [ ] **Step 1.5: Run tests to confirm they pass**

```bash
mix test test/shem/agent/checkpoint_test.exs
```

Expected: all tests pass.

- [ ] **Step 1.6: Full suite — no regressions**

```bash
mix test --exclude distributed
```

Expected: 0 failures.

- [ ] **Step 1.7: Commit**

```bash
git add lib/shem/agent/checkpoint.ex lib/shem/agent/server.ex test/shem/agent/checkpoint_test.exs
git commit -m "feat: add node field to checkpoint payload; log prior_node in agent_resumed"
```

---

## Task 2: PlacementStrategy + Transient Restart

**Files:**
- Create: `lib/shem/placement_strategy.ex`
- Modify: `lib/shem/agent_supervisor.ex`
- Modify: `test/shem/agent_supervisor_test.exs`

- [ ] **Step 2.1: Create PlacementStrategy**

Create `lib/shem/placement_strategy.ex`:

```elixir
defmodule Shem.PlacementStrategy do
  @behaviour Horde.DistributionStrategy

  @impl true
  def choose_node(child_spec, members) when members != [] do
    target = Map.get(child_spec, :placement_node)

    if target do
      case Enum.find(members, fn {_, n} -> n == target end) do
        nil -> Horde.UniformDistribution.choose_node(child_spec, members)
        member -> {:ok, member}
      end
    else
      Horde.UniformDistribution.choose_node(child_spec, members)
    end
  end

  def choose_node(_child_spec, []), do: {:error, :no_alive_nodes}
end
```

- [ ] **Step 2.2: Update AgentSupervisor init to use PlacementStrategy**

In `lib/shem/agent_supervisor.ex`, replace the `init/1` callback:

```elixir
@impl true
def init(_init_arg) do
  Horde.DynamicSupervisor.init(
    strategy: :one_for_one,
    members: :auto,
    distribution_strategy: Shem.PlacementStrategy
  )
end
```

- [ ] **Step 2.3: Change restart strategy to :transient**

In `lib/shem/agent_supervisor.ex`, in `start_agent/3`, replace the child_spec:

```elixir
child_spec = %{
  id: name,
  start: {Shem.Agent.Server, :start_link, [{name, config, session_id, [name: via]}]},
  restart: :transient
}
```

- [ ] **Step 2.4: Update the existing "not restarted" test**

The existing test asserts `:temporary` semantics (never restarted). With `:transient`, a killed process IS restarted; a cleanly stopped process is NOT. Update `test/shem/agent_supervisor_test.exs`:

Replace the test:
```elixir
test "a crashed agent is NOT restarted (:temporary restart strategy)" do
```

With:
```elixir
test "a cleanly stopped agent is NOT restarted (:transient restart strategy)" do
  Shem.LLM.StubTransport.Server.set_default(
    {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
  )
  config = %Agent.Config{task: "t", system_prompt: "s"}
  name = "test_agent_#{System.unique_integer([:positive])}"
  {:ok, pid, _sid} = AgentSupervisor.start_agent(name, config)
  GenServer.stop(pid, :normal)
  # Horde registry cleanup is async — give it time
  Process.sleep(300)
  via = Shem.ProcessRegistry.via_tuple(name)
  assert GenServer.whereis(via) == nil
end
```

- [ ] **Step 2.5: Run agent_supervisor tests**

```bash
mix test test/shem/agent_supervisor_test.exs
```

Expected: all tests pass.

- [ ] **Step 2.6: Full suite — no regressions**

```bash
mix test --exclude distributed
```

Expected: 0 failures.

- [ ] **Step 2.7: Commit**

```bash
git add lib/shem/placement_strategy.ex lib/shem/agent_supervisor.ex test/shem/agent_supervisor_test.exs
git commit -m "feat: add PlacementStrategy; change agent restart to :transient for Horde crash recovery"
```

---

## Task 3: NodeRegistry Core

**Files:**
- Create: `lib/shem/node_registry.ex`
- Create: `test/shem/node_registry_test.exs`

- [ ] **Step 3.1: Write the failing tests**

Create `test/shem/node_registry_test.exs`:

```elixir
defmodule Shem.NodeRegistryTest do
  use ExUnit.Case, async: false

  setup do
    # Start a fresh NodeRegistry for each test (not the app-level one)
    {:ok, pid} = Shem.NodeRegistry.start_link(name: nil)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{registry: pid}
  end

  test "labels/1 returns empty map for unknown node" do
    assert Shem.NodeRegistry.labels(:"unknown@nowhere") == %{}
  end

  test "own node labels are populated from config on start" do
    Application.put_env(:shem, :node_labels, %{"env" => "test"})
    {:ok, pid} = Shem.NodeRegistry.start_link(name: nil)
    on_exit(fn -> GenServer.stop(pid) end)
    assert Shem.NodeRegistry.labels(Node.self()) == %{"env" => "test"}
  after
    Application.delete_env(:shem, :node_labels)
  end

  test "set_labels/1 updates own node's labels" do
    Shem.NodeRegistry.set_labels(%{"role" => "worker"})
    assert Shem.NodeRegistry.labels(Node.self()) == %{"role" => "worker"}
  end

  test "nodes_matching/1 returns nodes whose labels are a superset of selector" do
    Shem.NodeRegistry.set_labels(%{"model" => "llama3", "gpu" => "true"})
    assert Node.self() in Shem.NodeRegistry.nodes_matching(%{"model" => "llama3"})
    assert Node.self() in Shem.NodeRegistry.nodes_matching(%{"model" => "llama3", "gpu" => "true"})
    assert Shem.NodeRegistry.nodes_matching(%{"model" => "gpt4"}) == []
  end

  test "nodes_matching/1 requires all selector keys to match" do
    Shem.NodeRegistry.set_labels(%{"model" => "llama3"})
    assert Shem.NodeRegistry.nodes_matching(%{"model" => "llama3", "gpu" => "true"}) == []
  end

  test "all/0 returns map of all known nodes" do
    Shem.NodeRegistry.set_labels(%{"x" => "1"})
    all = Shem.NodeRegistry.all()
    assert is_map(all)
    assert Map.has_key?(all, Node.self())
  end

  test "remove_node/1 deletes a node entry" do
    fake = :"fake@nowhere"
    Shem.NodeRegistry.put_node(fake, %{"role" => "removed"})
    assert Shem.NodeRegistry.labels(fake) == %{"role" => "removed"}
    Shem.NodeRegistry.remove_node(fake)
    assert Shem.NodeRegistry.labels(fake) == %{}
  end

  test "put_node/2 stores labels for an arbitrary node" do
    Shem.NodeRegistry.put_node(:"peer@host", %{"model" => "llama3"})
    assert Shem.NodeRegistry.labels(:"peer@host") == %{"model" => "llama3"}
  end
end
```

- [ ] **Step 3.2: Run to confirm failure**

```bash
mix test test/shem/node_registry_test.exs 2>&1 | head -10
```

Expected: compile error — `Shem.NodeRegistry` does not exist.

- [ ] **Step 3.3: Implement NodeRegistry**

Create `lib/shem/node_registry.ex`:

```elixir
defmodule Shem.NodeRegistry do
  use GenServer

  require Logger

  @table :shem_node_labels

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @spec labels(node()) :: %{String.t() => String.t()}
  def labels(node) do
    case :ets.lookup(@table, node) do
      [{^node, labels}] -> labels
      [] -> %{}
    end
  end

  @spec nodes_matching(%{String.t() => String.t()}) :: [node()]
  def nodes_matching(selector) when is_map(selector) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_node, labels} ->
      Enum.all?(selector, fn {k, v} -> Map.get(labels, k) == v end)
    end)
    |> Enum.map(fn {node, _} -> node end)
  end

  @spec set_labels(%{String.t() => String.t()}) :: :ok
  def set_labels(labels) when is_map(labels) do
    GenServer.call(__MODULE__, {:put_node, Node.self(), labels})
    Enum.each(Node.list(), fn peer ->
      :rpc.cast(peer, __MODULE__, :put_node, [Node.self(), labels])
    end)
    :ok
  end

  @spec put_node(node(), %{String.t() => String.t()}) :: :ok
  def put_node(node, labels) when is_map(labels) do
    GenServer.call(__MODULE__, {:put_node, node, labels})
  end

  @spec remove_node(node()) :: :ok
  def remove_node(node) do
    GenServer.call(__MODULE__, {:remove_node, node})
  end

  @spec sync_node(node()) :: :ok
  def sync_node(node) do
    GenServer.cast(__MODULE__, {:sync_node, node})
  end

  @spec all() :: %{node() => %{String.t() => String.t()}}
  def all do
    :ets.tab2list(@table) |> Map.new()
  end

  # ── Server ──────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table, {:read_concurrency, true}])
    own_labels = Application.get_env(:shem, :node_labels, %{})
    :ets.insert(@table, {Node.self(), own_labels})
    Enum.each(Node.list(), &do_sync_node/1)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put_node, node, labels}, _from, state) do
    :ets.insert(@table, {node, labels})
    {:reply, :ok, state}
  end

  def handle_call({:remove_node, node}, _from, state) do
    :ets.delete(@table, node)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:sync_node, node}, state) do
    do_sync_node(node)
    {:noreply, state}
  end

  defp do_sync_node(node) do
    case :rpc.call(node, Application, :get_env, [:shem, :node_labels, %{}]) do
      {:badrpc, reason} ->
        Logger.debug("NodeRegistry: could not sync #{node}: #{inspect(reason)}")

      labels when is_map(labels) ->
        :ets.insert(@table, {node, labels})

      _ ->
        :ok
    end
  end
end
```

- [ ] **Step 3.4: Run tests to confirm they pass**

```bash
mix test test/shem/node_registry_test.exs
```

Expected: all 8 tests pass.

- [ ] **Step 3.5: Full suite — no regressions**

```bash
mix test --exclude distributed
```

Expected: 0 failures.

- [ ] **Step 3.6: Commit**

```bash
git add lib/shem/node_registry.ex test/shem/node_registry_test.exs
git commit -m "feat: add Shem.NodeRegistry — ETS-backed node label registry with cluster sync"
```

---

## Task 4: NodeRegistry Cluster Integration + Application Wiring

**Files:**
- Modify: `lib/shem/application.ex`
- Modify: `lib/shem/cluster.ex`
- Modify: `test/shem/cluster_test.exs`

- [ ] **Step 4.1: Write failing tests**

In `test/shem/cluster_test.exs`, add a new describe block after the existing ones:

```elixir
describe "NodeRegistry integration" do
  test "nodeup causes NodeRegistry.sync_node to be called without crash" do
    {:ok, pid} = Shem.Cluster.start_link([])
    send(pid, {:nodeup, :"fake@127.0.0.1"})
    Process.sleep(100)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "nodedown causes node to be removed from NodeRegistry" do
    fake = :"fake_nr@127.0.0.1"
    Shem.NodeRegistry.put_node(fake, %{"role" => "worker"})
    {:ok, pid} = Shem.Cluster.start_link([])
    send(pid, {:nodedown, fake})
    Process.sleep(100)
    assert Shem.NodeRegistry.labels(fake) == %{}
    GenServer.stop(pid)
  end
end
```

- [ ] **Step 4.2: Run to confirm second test fails**

```bash
mix test test/shem/cluster_test.exs 2>&1 | tail -15
```

Expected: "nodedown causes node to be removed" fails — labels still present.

- [ ] **Step 4.3: Add NodeRegistry to application supervision tree**

In `lib/shem/application.ex`, add `Shem.NodeRegistry` to the children list, before `Shem.Cluster`:

```elixir
children =
  [
    {Horde.Registry, [name: Shem.Registry, keys: :unique, members: :auto]},
    Shem.AgentSupervisor,
    Shem.EventLog,
    Shem.Trust.Store,
    Shem.Memory.Store,
    Shem.Agent.PresetStore,
    Shem.LLM.Router,
    {Task.Supervisor, name: Shem.Lab.TaskSupervisor},
    Shem.Lab.Registry,
    Shem.LLM.BudgetServer,
    {Registry, keys: :duplicate, name: Shem.StreamRegistry},
    Shem.NodeRegistry       # ← add here
  ] ++
    adversarial_children() ++
    shadow_children() ++
    llm_stub_children() ++
    mcp_children() ++
    cluster_children() ++
    tui_children()
```

- [ ] **Step 4.4: Update Shem.Cluster to call NodeRegistry on node events**

In `lib/shem/cluster.ex`, update both `handle_info` callbacks:

```elixir
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
```

- [ ] **Step 4.5: Run cluster tests**

```bash
mix test test/shem/cluster_test.exs
```

Expected: all tests pass.

- [ ] **Step 4.6: Full suite — no regressions**

```bash
mix test --exclude distributed
```

Expected: 0 failures.

- [ ] **Step 4.7: Commit**

```bash
git add lib/shem/application.ex lib/shem/cluster.ex test/shem/cluster_test.exs
git commit -m "feat: wire NodeRegistry into application and Cluster node event handlers"
```

---

## Task 5: Placement Hints in Agent.Config + AgentSupervisor

**Files:**
- Modify: `lib/shem/agent.ex`
- Modify: `lib/shem/process_registry.ex`
- Modify: `lib/shem/agent_supervisor.ex`
- Modify: `test/shem/agent_supervisor_test.exs`

- [ ] **Step 5.1: Write failing tests**

Add to `test/shem/agent_supervisor_test.exs`:

```elixir
describe "placement" do
  setup do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    :ok
  end

  test "placement :any starts agent without placement_miss event" do
    config = %Agent.Config{task: "t", system_prompt: "s", placement: :any}
    name = "test_place_any_#{System.unique_integer([:positive])}"
    {:ok, _pid, session_id} = AgentSupervisor.start_agent(name, config)
    {:ok, events} = Shem.EventLog.events(session_id)
    refute Enum.any?(events, &(&1.type == :placement_miss))
  end

  test "placement {:node, self()} starts agent successfully" do
    config = %Agent.Config{task: "t", system_prompt: "s", placement: {:node, Node.self()}}
    name = "test_place_node_#{System.unique_integer([:positive])}"
    assert {:ok, _pid, _sid} = AgentSupervisor.start_agent(name, config)
  end

  test "placement {:node, unknown} returns error" do
    config = %Agent.Config{task: "t", system_prompt: "s", placement: {:node, :"ghost@nowhere"}}
    name = "test_place_bad_#{System.unique_integer([:positive])}"
    assert {:error, :no_matching_node} = AgentSupervisor.start_agent(name, config)
  end

  test "placement {:labels, selector} with no match falls back to :any and logs placement_miss" do
    config = %Agent.Config{
      task: "t",
      system_prompt: "s",
      placement: {:labels, %{"model" => "nonexistent-model"}}
    }
    name = "test_place_label_miss_#{System.unique_integer([:positive])}"
    assert {:ok, _pid, session_id} = AgentSupervisor.start_agent(name, config)
    # Wait for agent to start and open its session
    Process.sleep(200)
    {:ok, events} = Shem.EventLog.events(session_id)
    assert Enum.any?(events, &(&1.type == :placement_miss))
  end

  test "placement {:labels, selector, :required} with no match returns error" do
    config = %Agent.Config{
      task: "t",
      system_prompt: "s",
      placement: {:labels, %{"model" => "nonexistent-model"}, :required}
    }
    name = "test_place_label_req_#{System.unique_integer([:positive])}"
    assert {:error, :no_matching_node} = AgentSupervisor.start_agent(name, config)
  end
end
```

- [ ] **Step 5.2: Run to confirm failures**

```bash
mix test test/shem/agent_supervisor_test.exs 2>&1 | tail -20
```

Expected: compile errors — `placement` field doesn't exist on `Agent.Config`.

- [ ] **Step 5.3: Add placement field to Agent.Config**

In `lib/shem/agent.ex`, update the `Config` defstruct and type:

```elixir
defmodule Config do
  @enforce_keys [:task, :system_prompt]
  defstruct [:task, :system_prompt, model: :default, tools: [], max_turns: 20,
             spawn_depth: 0, conversational: false, project_context: nil, fence: nil,
             placement: :any]

  @type placement ::
          :any
          | {:node, node()}
          | {:labels, %{String.t() => String.t()}}
          | {:labels, %{String.t() => String.t()}, :required}

  @type t :: %__MODULE__{
          task: String.t(),
          system_prompt: String.t(),
          model: atom(),
          tools: [String.t()],
          max_turns: pos_integer(),
          spawn_depth: non_neg_integer(),
          project_context: Shem.Context.Project.t() | nil,
          conversational: boolean(),
          fence: String.t() | nil,
          placement: placement()
        }
end
```

- [ ] **Step 5.4: Update ProcessRegistry to store placement metadata**

In `lib/shem/process_registry.ex`, replace the entire file:

```elixir
defmodule Shem.ProcessRegistry do
  @registry Shem.Registry

  @spec via_tuple(term()) :: {:via, Horde.Registry, {atom(), term()}}
  def via_tuple(name), do: {:via, Horde.Registry, {@registry, name}}

  @spec via_tuple(term(), term()) :: {:via, Horde.Registry, {atom(), term(), term()}}
  def via_tuple(name, value), do: {:via, Horde.Registry, {@registry, name, value}}

  @spec via_tuple_with_meta(term(), String.t(), map()) ::
          {:via, Horde.Registry, {atom(), term(), map()}}
  def via_tuple_with_meta(name, session_id, meta) do
    {:via, Horde.Registry, {@registry, name, Map.put(meta, :session_id, session_id)}}
  end

  @spec lookup(term()) :: {pid(), String.t()} | nil
  def lookup(name) do
    case Horde.Registry.lookup(@registry, name) do
      [{pid, %{session_id: sid}}] -> {pid, sid}
      [{pid, value}] when is_binary(value) -> {pid, value}
      [] -> nil
    end
  end

  @spec lookup_meta(term()) :: {pid(), map()} | nil
  def lookup_meta(name) do
    case Horde.Registry.lookup(@registry, name) do
      [{pid, value}] when is_map(value) -> {pid, value}
      [{pid, value}] when is_binary(value) -> {pid, %{session_id: value}}
      [] -> nil
    end
  end
end
```

- [ ] **Step 5.5: Add resolve_placement/1 and update start_agent in AgentSupervisor**

In `lib/shem/agent_supervisor.ex`, replace `start_agent/2` and `start_agent/3` and add `resolve_placement/1`:

```elixir
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
```

- [ ] **Step 5.6: Run agent_supervisor tests**

```bash
mix test test/shem/agent_supervisor_test.exs
```

Expected: all tests pass.

- [ ] **Step 5.7: Full suite — no regressions**

```bash
mix test --exclude distributed
```

Expected: 0 failures.

- [ ] **Step 5.8: Commit**

```bash
git add lib/shem/agent.ex lib/shem/process_registry.ex lib/shem/agent_supervisor.ex test/shem/agent_supervisor_test.exs
git commit -m "feat: add placement hints to Agent.Config; resolve_placement in AgentSupervisor with soft/strict label matching"
```

---

## Task 6: flush_checkpoint + evac_spec Handlers

**Files:**
- Modify: `lib/shem/agent/server.ex`
- Modify: `test/shem/agent/server_test.exs`

- [ ] **Step 6.1: Write failing tests**

Use a conversational agent so the GenServer is in `:waiting` state (not blocked mid-LLM-call) when we call flush. Add to `test/shem/agent/server_test.exs` inside the existing module:

```elixir
describe "flush_checkpoint" do
  setup do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "hello", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    config = %Shem.Agent.Config{task: "say hello", system_prompt: "s", conversational: true}
    name = "flush_test_#{System.unique_integer([:positive])}"
    {:ok, pid, session_id} = Shem.AgentSupervisor.start_agent(name, config)
    # Wait for agent to complete first turn and reach :waiting
    Process.sleep(300)
    %{pid: pid, session_id: session_id}
  end

  test "flush_checkpoint writes a checkpoint and sets status to :evacuating", %{pid: pid, session_id: session_id} do
    assert :ok = GenServer.call(pid, :flush_checkpoint, 2_000)
    state = :sys.get_state(pid)
    assert state.status == :evacuating
    {:ok, events} = Shem.EventLog.events(session_id)
    # At least 2 checkpoints: one from run_turn, one from flush
    assert Enum.count(events, &(&1.type == :agent_checkpoint)) >= 2
  end

  test "evac_spec returns name, config, and session_id", %{pid: pid, session_id: session_id} do
    {name, config, sid} = GenServer.call(pid, :evac_spec)
    assert is_binary(name)
    assert %Shem.Agent.Config{} = config
    assert sid == session_id
  end
end
```

- [ ] **Step 6.3: Run tests to confirm failure**

```bash
mix test test/shem/agent/server_test.exs 2>&1 | grep -A5 "flush_checkpoint"
```

Expected: failures — `:flush_checkpoint` not handled.

- [ ] **Step 6.4: Add handlers to Agent.Server**


In `lib/shem/agent/server.ex`, add after the `:unpause` handler (around line 75):

```elixir
def handle_call(:flush_checkpoint, _from, state) do
  Checkpoint.save(state.session_id, state)
  {:reply, :ok, %{state | status: :evacuating}}
end

def handle_call(:evac_spec, _from, state) do
  {:reply, {state.name, state.config, state.session_id}, state}
end
```

Also update `handle_info(:run_turn)` guard to include `:evacuating` — find this line:

```elixir
def handle_info(:run_turn, %{status: s} = state) when s != :running do
```

It already guards against non-running states, so `:evacuating` is automatically handled — confirm `when s != :running` covers it (it does).

- [ ] **Step 6.5: Run server tests**

```bash
mix test test/shem/agent/server_test.exs
```

Expected: all tests pass.

- [ ] **Step 6.6: Full suite — no regressions**

```bash
mix test --exclude distributed
```

Expected: 0 failures.

- [ ] **Step 6.7: Commit**

```bash
git add lib/shem/agent/server.ex test/shem/agent/server_test.exs
git commit -m "feat: add :flush_checkpoint and :evac_spec handlers to Agent.Server"
```


---

## Task 7: evacuate_all/0

**Files:**
- Modify: `lib/shem/agent_supervisor.ex`
- Modify: `test/shem/agent_supervisor_test.exs`

- [ ] **Step 7.1: Write failing test**

Use a conversational agent in `:waiting` state so `flush_checkpoint` can be called without timeout. Add to `test/shem/agent_supervisor_test.exs`:

```elixir
describe "evacuate_all/0" do
  test "flushes checkpoint for each local agent" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    config = %Agent.Config{task: "say done", system_prompt: "s", conversational: true}
    name = "evac_test_#{System.unique_integer([:positive])}"
    {:ok, _pid, session_id} = AgentSupervisor.start_agent(name, config)
    # Wait for agent to reach :waiting state after first turn
    Process.sleep(300)

    AgentSupervisor.evacuate_all()

    # flush_checkpoint writes an additional checkpoint beyond the run_turn one
    {:ok, events} = Shem.EventLog.events(session_id)
    assert Enum.count(events, &(&1.type == :agent_checkpoint)) >= 2
  end
end
```

- [ ] **Step 7.2: Run to confirm failure**

```bash
mix test test/shem/agent_supervisor_test.exs 2>&1 | grep -A5 "evacuate_all"
```

Expected: `AgentSupervisor.evacuate_all/0 is undefined`.

- [ ] **Step 7.3: Implement evacuate_all/0 in AgentSupervisor**

Add to `lib/shem/agent_supervisor.ex`, after the `start_agent` functions:

```elixir
@doc """
Flushes checkpoints for all agents running on this node, then pushes each agent
to a surviving peer node. Called by Shem.Cluster.terminate/2 on graceful shutdown.
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

    target_node =
      if survivors == [] do
        nil
      else
        case config.placement do
          {:labels, selector} ->
            matches = Shem.NodeRegistry.nodes_matching(selector) |> Enum.reject(&(&1 == Node.self()))
            if matches != [], do: Enum.random(matches), else: Enum.random(survivors)

          {:labels, selector, _} ->
            matches = Shem.NodeRegistry.nodes_matching(selector) |> Enum.reject(&(&1 == Node.self()))
            if matches != [], do: Enum.random(matches), else: Enum.random(survivors)

          {:node, n} when n != Node.self() ->
            if n in survivors, do: n, else: Enum.random(survivors)

          _ ->
            Enum.random(survivors)
        end
      end

    # Step 4: push to target (if available)
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

    # Step 5: clean-stop the local copy
    Horde.DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
```

- [ ] **Step 7.4: Run agent_supervisor tests**

```bash
mix test test/shem/agent_supervisor_test.exs
```

Expected: all tests pass.

- [ ] **Step 7.5: Full suite — no regressions**

```bash
mix test --exclude distributed
```

Expected: 0 failures.

- [ ] **Step 7.6: Commit**

```bash
git add lib/shem/agent_supervisor.ex test/shem/agent_supervisor_test.exs
git commit -m "feat: add AgentSupervisor.evacuate_all/0 — checkpoint flush + push handoff to surviving nodes"
```

---

## Task 8: Cluster SIGTERM Interception

**Files:**
- Modify: `lib/shem/cluster.ex`
- Modify: `test/shem/cluster_test.exs`

- [ ] **Step 8.1: Write failing test**

Add to `test/shem/cluster_test.exs`:

```elixir
describe "graceful shutdown" do
  test "Cluster traps exits and terminate/2 is called on GenServer.stop" do
    {:ok, pid} = Shem.Cluster.start_link([])
    # stop with :normal — terminate/2 should be called (trap_exit means we handle it)
    GenServer.stop(pid, :normal)
    # If terminate/2 raises, the test would fail; passing means it completed cleanly
    refute Process.alive?(pid)
  end
end
```

- [ ] **Step 8.2: Run to confirm current behavior**

```bash
mix test test/shem/cluster_test.exs 2>&1 | tail -10
```

This test will likely pass already (GenServer.stop is clean), but we need to verify `terminate/2` actually runs. The real test is behavioral — we'll verify evacuation integration in the distributed tests. For now this confirms `terminate/2` doesn't crash.

- [ ] **Step 8.3: Add trap_exit and terminate/2 to Shem.Cluster**

In `lib/shem/cluster.ex`, update `init/1` and add `terminate/2`:

```elixir
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
  {:ok, %{}}
end

@impl true
def terminate(_reason, _state) do
  Logger.info("Shem.Cluster: graceful shutdown — evacuating agents")
  Shem.AgentSupervisor.evacuate_all()
end
```

- [ ] **Step 8.4: Run cluster tests**

```bash
mix test test/shem/cluster_test.exs
```

Expected: all tests pass.

- [ ] **Step 8.5: Full suite — no regressions**

```bash
mix test --exclude distributed
```

Expected: 0 failures.

- [ ] **Step 8.6: Commit**

```bash
git add lib/shem/cluster.ex test/shem/cluster_test.exs
git commit -m "feat: trap exits in Shem.Cluster; terminate/2 calls evacuate_all on graceful shutdown"
```

---

## Task 9: Distributed Failover Tests

**Files:**
- Create: `test/shem/distributed/failover_test.exs`

Run with:
```bash
elixir --sname shem_test -S mix test --only distributed
```

- [ ] **Step 9.1: Write the distributed tests**

Create `test/shem/distributed/failover_test.exs`:

```elixir
defmodule Shem.Distributed.FailoverTest do
  use ExUnit.Case, async: false

  @moduletag :distributed

  # Run with:
  #   elixir --sname shem_test -S mix test --only distributed

  alias Shem.Agent

  setup_all do
    unless Node.alive?() do
      Node.start(:shem_test, :shortnames)
    end

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp start_peer(short_name) do
    build_path = Mix.Project.build_path()
    elixir_lib = :code.lib_dir(:elixir) |> Path.dirname() |> to_string()

    pa_args =
      (Path.wildcard(Path.join([elixir_lib, "*", "ebin"])) ++
         Path.wildcard(Path.join([build_path, "lib", "*", "ebin"])))
      |> Enum.flat_map(fn p -> [~c"-pa", String.to_charlist(p)] end)

    {:ok, peer, node} =
      :peer.start(%{
        name: short_name,
        args: pa_args
      })

    :rpc.call(node, :application, :ensure_all_started, [:elixir])
    :rpc.call(node, :application, :ensure_all_started, [:mnesia])
    {:ok, peer, node}
  end

  defp assert_eventually(fun, timeout_ms, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if fun.() do
        :ok
      else
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(interval_ms)
          :retry
        else
          :timeout
        end
      end
    end)
    |> Enum.find(fn r -> r in [:ok, :timeout] end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("Condition not met within #{timeout_ms}ms")
    end
  end

  defp setup_peer_app(peer_node) do
    self_node = Node.self()

    :rpc.call(peer_node, Code, :eval_string, [
      """
      # Start Horde services using the module's own start_link so init/1 runs correctly
      {:ok, _} = Horde.Registry.start_link(name: Shem.Registry, keys: :unique, members: :auto)
      {:ok, _} = Shem.AgentSupervisor.start_link([])
      # Connect Horde members across both nodes
      all = [node(), :"#{self_node}"]
      Horde.Cluster.set_members(Shem.Registry, Enum.map(all, &{Shem.Registry, &1}))
      Horde.Cluster.set_members(Shem.AgentSupervisor, Enum.map(all, &{Shem.AgentSupervisor, &1}))
      # Set up Mnesia
      Application.ensure_all_started(:mnesia)
      :mnesia.change_config(:extra_db_nodes, [:"#{self_node}"])
      case :mnesia.add_table_copy(:shem_events, node(), :disc_copies) do
        {:atomic, :ok} -> :ok
        {:aborted, {:already_exists, :shem_events, _}} -> :ok
      end
      :mnesia.wait_for_tables([:shem_events], 10_000)
      """
    ])

    # Also sync Horde on local node
    all_nodes = [Node.self(), peer_node]
    Horde.Cluster.set_members(Shem.AgentSupervisor, Enum.map(all_nodes, &{Shem.AgentSupervisor, &1}))
    Horde.Cluster.set_members(Shem.Registry, Enum.map(all_nodes, &{Shem.Registry, &1}))
    Process.sleep(300)
  end

  # ── Tests ────────────────────────────────────────────────────────────────────

  test "crash recovery: agent on peer node A restarts on local node B after A dies" do
    {:ok, peer, peer_node} = start_peer(:shem_fo_crash)
    on_exit(fn -> catch_exit(:peer.stop(peer)) end)

    setup_peer_app(peer_node)

    # Start agent on peer node
    session_id = "ses_crash_#{:erlang.unique_integer([:positive])}"
    agent_name = "agent_crash_#{:erlang.unique_integer([:positive])}"

    :rpc.call(peer_node, Code, :eval_string, [
      """
      config = %Shem.Agent.Config{
        task: "count to ten",
        system_prompt: "you count",
        max_turns: 50
      }
      Shem.AgentSupervisor.start_agent("#{agent_name}", config, "#{session_id}")
      """
    ])

    # Wait for at least one checkpoint to be written to Mnesia
    assert_eventually(
      fn ->
        case Shem.EventLog.MnesiaStore.read_all(session_id) do
          {:ok, events} -> Enum.any?(events, &(&1.type == :agent_checkpoint))
          _ -> false
        end
      end,
      5_000
    )

    # Kill peer node — agent processes exit abnormally
    :peer.stop(peer)

    # Horde should redistribute the :transient agent to local node
    assert_eventually(
      fn ->
        case Horde.Registry.lookup(Shem.Registry, agent_name) do
          [{pid, _}] -> node(pid) == Node.self()
          _ -> false
        end
      end,
      5_000
    )

    # Resumed agent should have logged :agent_resumed with prior_node
    assert_eventually(
      fn ->
        case Shem.EventLog.MnesiaStore.read_all(session_id) do
          {:ok, events} ->
            Enum.any?(events, fn e ->
              e.type == :agent_resumed && Map.get(e.payload, :prior_node) == peer_node
            end)

          _ ->
            false
        end
      end,
      5_000
    )
  end

  test "graceful evacuation: stopping peer pushes agent to local node before shutdown" do
    {:ok, peer, peer_node} = start_peer(:shem_fo_evac)
    on_exit(fn -> catch_exit(:peer.stop(peer)) end)

    setup_peer_app(peer_node)

    # Start the LLM stub and Cluster on peer so evacuation can run
    :rpc.call(peer_node, Code, :eval_string, [
      """
      {:ok, _} = Shem.LLM.StubTransport.Server.start_link(
        name: Shem.LLM.StubTransport.Server
      )
      Shem.LLM.StubTransport.Server.set_default(:hang)
      {:ok, _} = Shem.Cluster.start_link([])
      """
    ])

    session_id = "ses_evac_#{:erlang.unique_integer([:positive])}"
    agent_name = "agent_evac_#{:erlang.unique_integer([:positive])}"

    :rpc.call(peer_node, Code, :eval_string, [
      """
      config = %Shem.Agent.Config{task: "hang", system_prompt: "s", max_turns: 50}
      Shem.AgentSupervisor.start_agent("#{agent_name}", config, "#{session_id}")
      """
    ])

    Process.sleep(300)

    # Trigger graceful shutdown on peer — Cluster.terminate/2 runs evacuate_all
    :rpc.call(peer_node, Code, :eval_string, [
      "Shem.AgentSupervisor.evacuate_all()"
    ])

    # Agent should appear on local node
    assert_eventually(
      fn ->
        case Horde.Registry.lookup(Shem.Registry, agent_name) do
          [{pid, _}] -> node(pid) == Node.self()
          _ -> false
        end
      end,
      5_000
    )

    # Checkpoint written before handoff
    {:ok, events} = Shem.EventLog.MnesiaStore.read_all(session_id)
    assert Enum.any?(events, &(&1.type == :agent_checkpoint))
  end

  test "placement {:labels, selector} routes agent to matching node" do
    {:ok, peer, peer_node} = start_peer(:shem_fo_place)
    on_exit(fn -> catch_exit(:peer.stop(peer)) end)

    setup_peer_app(peer_node)

    # Give peer node a label
    :rpc.call(peer_node, Code, :eval_string, [
      """
      Shem.NodeRegistry.set_labels(%{"model" => "llama3-test"})
      """
    ])

    # Wait for label to propagate to local NodeRegistry
    assert_eventually(
      fn ->
        Shem.NodeRegistry.nodes_matching(%{"model" => "llama3-test"}) != []
      end,
      3_000
    )

    # Start agent with label placement
    config = %Shem.Agent.Config{
      task: "t",
      system_prompt: "s",
      placement: {:labels, %{"model" => "llama3-test"}}
    }

    agent_name = "agent_place_#{:erlang.unique_integer([:positive])}"
    {:ok, pid, _sid} = Shem.AgentSupervisor.start_agent(agent_name, config)

    # Agent should be on peer node
    assert node(pid) == peer_node
  end
end
```

- [ ] **Step 9.2: Run the distributed tests**

```bash
elixir --sname shem_test -S mix test --only distributed 2>&1 | tail -30
```

Expected: all 3 tests pass. If crash recovery test is flaky (Horde redistribution timing), increase the `assert_eventually` timeout to 8_000.

- [ ] **Step 9.3: Run non-distributed suite — no regressions**

```bash
mix test --exclude distributed
```

Expected: 0 failures.

- [ ] **Step 9.4: Commit**

```bash
git add test/shem/distributed/failover_test.exs
git commit -m "test: distributed failover tests — crash recovery, graceful evacuation, label placement"
```

---

## Task 10: North Star + Memory Update

- [ ] **Step 10.1: Update PROJECT_NORTH_STAR.md**

In `PROJECT_NORTH_STAR.md`, replace the Current Phase section:

```markdown
## Current Phase
**Phase 41 — Node-aware TUI, Streaming & API**: Final distributed mesh phase (38–41).
Goal: TUI and API present the full cluster as a unified surface; remote agent tokens stream to local TUI with identical fidelity.
Spec: `docs/superpowers/specs/2026-06-13-distributed-mesh-design.md`.

**Phase 40 — Agent Failover, Evacuation & Placement**: COMPLETE. `:transient` restart strategy enables Horde crash recovery; `Shem.NodeRegistry` provides dynamic ETS-backed node label registry; `Agent.Config.placement` with soft/strict label matching; `AgentSupervisor.evacuate_all/0` implements SIGTERM push-handoff; `Shem.Cluster.terminate/2` wires evacuation to graceful shutdown.
```

Also update `_Last updated: 2026-06-13` date if needed.

- [ ] **Step 10.2: Commit**

```bash
git add PROJECT_NORTH_STAR.md
git commit -m "docs: mark Phase 40 complete, advance to Phase 41"
```
