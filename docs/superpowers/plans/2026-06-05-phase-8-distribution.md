# Phase 8: Distribution Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add BEAM-native distribution to Shem — Horde-backed cluster-aware registry and supervisor, EventLog-based agent checkpoint/resume, optional remote Lab execution, and per-node LLM budget.

**Architecture:** `libcluster` (Gossip strategy) handles node discovery; `Horde.Registry` and `Horde.DynamicSupervisor` (both with `members: :auto`) replace local equivalents — no manual member management needed. Agent state is checkpointed to EventLog before each LLM turn; on Horde-triggered redistribution after node death, `Agent.Server.init/1` reconstructs state from the latest checkpoint.

**Tech Stack:** Elixir/OTP 29, `horde ~> 0.9`, `libcluster ~> 3.3`, existing DETS EventLog, `:rpc.call` for remote Lab execution.

---

## File Map

**New files:**
- `lib/shem/cluster.ex` — GenServer; node monitoring, `nodes/0`
- `lib/shem/agent/checkpoint.ex` — Pure module; `save/2`, `reconstruct/1`
- `test/shem/cluster_test.exs`
- `test/shem/agent/checkpoint_test.exs`

**Modified files:**
- `mix.exs` — add `horde`, `libcluster`
- `config/dev.exs` — libcluster topology, `budget_node_tokens`, `lab_executor_node`, `start_cluster`
- `config/test.exs` — `start_cluster: false`
- `lib/shem/event_log.ex` — add `start_session/1` arity-1 variant (external session_id)
- `lib/shem/application.ex` — replace `Registry` with `Horde.Registry`, add `Shem.Cluster` child
- `lib/shem/process_registry.ex` — update `via_tuple/1` to use `Horde.Registry`
- `lib/shem/agent_supervisor.ex` — use `Horde.DynamicSupervisor`, generate `session_id` upstream
- `lib/shem/agent/server.ex` — accept `session_id` in init, checkpoint save, resume from checkpoint
- `lib/shem/llm/budget_server.ex` — read `budget_node_tokens` config key
- `lib/shem/lab/executor.ex` — add `node:` opt for remote dispatch
- `lib/shem/lab/graduation_gate.ex` — pass `lab_executor_node` config to `Executor.run`
- `lib/shem/tui/app.ex` — add `cluster_node_count` field + tick update
- `lib/shem/tui/views/dashboard.ex` — add `Cluster: N nodes` label
- `test/shem/agent_supervisor_test.exs` — update for new signature
- `test/shem/agent/server_test.exs` — update for new init signature, add checkpoint/resume tests

---

## Task 1: Add deps and config

**Files:**
- Modify: `mix.exs`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Add horde and libcluster to mix.exs**

Replace the `deps` list in `mix.exs`:

```elixir
defp deps do
  [
    {:ratatouille, "~> 0.5"},
    {:stream_data, "~> 1.0", only: :test},
    {:bandit, "~> 1.0"},
    {:plug, "~> 1.16"},
    {:jason, "~> 1.4"},
    {:req, "~> 0.5"},
    {:horde, "~> 0.9"},
    {:libcluster, "~> 3.3"}
  ]
end
```

- [ ] **Step 2: Add cluster config to config/dev.exs**

Append to `config/dev.exs`:

```elixir
config :libcluster,
  topologies: [
    shem: [
      strategy: Cluster.Strategy.Gossip,
      config: [port: 45892, multicast_addr: "230.1.1.251"]
    ]
  ]

config :shem, start_cluster: true
config :shem, budget_node_tokens: 500_000
config :shem, lab_executor_node: nil
```

- [ ] **Step 3: Disable cluster in test config**

Append to `config/test.exs`:

```elixir
config :shem, start_cluster: false
config :shem, lab_executor_node: nil
```

- [ ] **Step 4: Fetch deps**

```bash
cd /home/philip/Downloads/_project/shem && mix deps.get
```

Expected: deps fetched successfully, no errors.

- [ ] **Step 5: Verify existing tests still pass**

```bash
mix test
```

Expected: same test count as before (306), all passing.

- [ ] **Step 6: Commit**

```bash
git add mix.exs mix.lock config/dev.exs config/test.exs
git commit -m "chore: add horde and libcluster deps; cluster config"
```

---

## Task 2: EventLog.start_session/1 — accept external session_id

The current `start_session/0` always generates a new UUID. Agent migration needs to reopen a known session_id. We add a `start_session/1` that accepts an external id and either loads the existing DETS file or creates a fresh one.

**Files:**
- Modify: `lib/shem/event_log.ex`
- Test: `test/shem/event_log_test.exs`

- [ ] **Step 1: Write the failing test**

Find `test/shem/event_log_test.exs` and add inside the module:

```elixir
describe "start_session/1 (external id)" do
  test "opens a session with the provided id" do
    id = "ses_AABBCCDD11223344"
    assert {:ok, ^id} = Shem.EventLog.start_session(id)
    {:ok, sessions} = Shem.EventLog.list_sessions()
    assert Enum.any?(sessions, &(&1.id == id))
  end

  test "calling start_session/1 twice with same id returns ok without duplicating" do
    id = "ses_DUPLICATE00000001"
    assert {:ok, ^id} = Shem.EventLog.start_session(id)
    assert {:ok, ^id} = Shem.EventLog.start_session(id)
    {:ok, sessions} = Shem.EventLog.list_sessions()
    assert Enum.count(sessions, &(&1.id == id)) == 1
  end

  test "events appended after start_session/1 are retrievable" do
    id = "ses_EXTERNAL00000001"
    {:ok, ^id} = Shem.EventLog.start_session(id)
    {:ok, _} = Shem.EventLog.append(id, :test_event, %{val: 42})
    assert {:ok, events} = Shem.EventLog.events(id)
    assert length(events) == 1
    assert hd(events).type == :test_event
  end
end
```

- [ ] **Step 2: Run test to confirm failure**

```bash
mix test test/shem/event_log_test.exs --seed 0
```

Expected: fails with "undefined function start_session/1" or similar.

- [ ] **Step 3: Add start_session/1 public API to event_log.ex**

In `lib/shem/event_log.ex`, after the existing `start_session/0` spec and definition, add:

```elixir
@spec start_session(String.t()) :: {:ok, String.t()}
def start_session(session_id), do: GenServer.call(__MODULE__, {:start_session, session_id})
```

- [ ] **Step 4: Add handle_call for {:start_session, session_id}**

In `lib/shem/event_log.ex`, after the existing `handle_call(:start_session, ...)` clause, add:

```elixir
@impl true
def handle_call({:start_session, session_id}, _from, state) do
  case Map.fetch(state.sessions, session_id) do
    {:ok, _} ->
      {:reply, {:ok, session_id}, state}

    :error ->
      session = %Shem.EventLog.Session{id: session_id, started_at: DateTime.utc_now()}
      {:ok, handle} = state.store.open(session_id, event_log_path())
      sessions = Map.put(state.sessions, session_id, {handle, session})
      {:reply, {:ok, session_id}, %{state | sessions: sessions}}
  end
end
```

- [ ] **Step 5: Run tests**

```bash
mix test test/shem/event_log_test.exs --seed 0
```

Expected: all EventLog tests pass.

- [ ] **Step 6: Run full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/event_log.ex test/shem/event_log_test.exs
git commit -m "feat: EventLog.start_session/1 accepts external session_id"
```

---

## Task 3: Shem.Agent.Checkpoint

Pure module with `save/2` (appends `:agent_checkpoint` to EventLog) and `reconstruct/1` (finds latest checkpoint in a session). The session **must** be open in EventLog before calling either function.

**Files:**
- Create: `lib/shem/agent/checkpoint.ex`
- Create: `test/shem/agent/checkpoint_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/shem/agent/checkpoint_test.exs`:

```elixir
defmodule Shem.Agent.CheckpointTest do
  use ExUnit.Case, async: false

  alias Shem.Agent.{Checkpoint, Config}
  alias Shem.EventLog

  defp open_session(id) do
    {:ok, ^id} = EventLog.start_session(id)
    id
  end

  defp make_state(turn_count \\ 2) do
    %{
      history: [
        %{role: :user, content: "do something"},
        %{role: :assistant, content: "I'll help"}
      ],
      turn_count: turn_count,
      config: %Config{task: "do something", system_prompt: "helpful"}
    }
  end

  describe "save/2" do
    test "appends :agent_checkpoint event to the session" do
      id = open_session("ses_CKPT_SAVE_#{System.unique_integer([:positive])}")
      state = make_state()
      assert :ok = Checkpoint.save(id, state)
      {:ok, events} = EventLog.events(id)
      assert Enum.any?(events, &(&1.type == :agent_checkpoint))
    end

    test "checkpoint payload contains history, turn_count, and config" do
      id = open_session("ses_CKPT_PAYLOAD_#{System.unique_integer([:positive])}")
      state = make_state(5)
      Checkpoint.save(id, state)
      {:ok, events} = EventLog.events(id)
      event = Enum.find(events, &(&1.type == :agent_checkpoint))
      assert event.payload.turn_count == 5
      assert event.payload.history == state.history
      assert event.payload.config == state.config
    end
  end

  describe "reconstruct/1" do
    test "returns :not_found when session has no checkpoints" do
      id = open_session("ses_CKPT_NOTFOUND_#{System.unique_integer([:positive])}")
      assert :not_found = Checkpoint.reconstruct(id)
    end

    test "returns :not_found when session does not exist" do
      assert :not_found = Checkpoint.reconstruct("ses_NONEXISTENT_XYZ")
    end

    test "returns {:ok, checkpoint} after a save" do
      id = open_session("ses_CKPT_ROUNDTRIP_#{System.unique_integer([:positive])}")
      state = make_state(3)
      Checkpoint.save(id, state)
      assert {:ok, checkpoint} = Checkpoint.reconstruct(id)
      assert checkpoint.turn_count == 3
      assert checkpoint.history == state.history
    end

    test "returns the LATEST checkpoint when multiple exist" do
      id = open_session("ses_CKPT_LATEST_#{System.unique_integer([:positive])}")
      Checkpoint.save(id, make_state(1))
      Checkpoint.save(id, make_state(2))
      Checkpoint.save(id, make_state(7))
      assert {:ok, checkpoint} = Checkpoint.reconstruct(id)
      assert checkpoint.turn_count == 7
    end

    test "round-trip: save then reconstruct returns identical state fields" do
      id = open_session("ses_CKPT_IDENTICAL_#{System.unique_integer([:positive])}")
      state = make_state(4)
      Checkpoint.save(id, state)
      {:ok, checkpoint} = Checkpoint.reconstruct(id)
      assert checkpoint.turn_count == state.turn_count
      assert checkpoint.history == state.history
      assert checkpoint.config == state.config
    end
  end
end
```

- [ ] **Step 2: Run test to confirm failure**

```bash
mix test test/shem/agent/checkpoint_test.exs --seed 0
```

Expected: fails — module does not exist.

- [ ] **Step 3: Create lib/shem/agent/checkpoint.ex**

```elixir
defmodule Shem.Agent.Checkpoint do
  alias Shem.EventLog

  @spec save(String.t(), map()) :: :ok
  def save(session_id, state) do
    EventLog.append(session_id, :agent_checkpoint, %{
      history: state.history,
      turn_count: state.turn_count,
      config: state.config
    })
    :ok
  end

  @spec reconstruct(String.t()) :: {:ok, map()} | :not_found
  def reconstruct(session_id) do
    case EventLog.events(session_id) do
      {:ok, events} ->
        events
        |> Enum.filter(&(&1.type == :agent_checkpoint))
        |> List.last()
        |> case do
          nil -> :not_found
          event -> {:ok, event.payload}
        end

      _ ->
        :not_found
    end
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/agent/checkpoint_test.exs --seed 0
```

Expected: all 7 tests pass.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/agent/checkpoint.ex test/shem/agent/checkpoint_test.exs
git commit -m "feat: Shem.Agent.Checkpoint — save/2 and reconstruct/1"
```

---

## Task 4: Shem.Cluster GenServer

Monitors node events and exposes `nodes/0`. The supervisor and registry use `members: :auto` (pg-backed), so no manual Horde member management is needed here. `Shem.Cluster` exists for observability and future node-event hooks.

**Files:**
- Create: `lib/shem/cluster.ex`
- Create: `test/shem/cluster_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/shem/cluster_test.exs`:

```elixir
defmodule Shem.ClusterTest do
  use ExUnit.Case, async: true

  describe "nodes/0" do
    test "returns a list containing at least the current node" do
      nodes = Shem.Cluster.nodes()
      assert is_list(nodes)
      assert Node.self() in nodes
    end

    test "works without the GenServer running (pure function)" do
      # nodes/0 calls Node.self() | Node.list() directly — no GenServer needed
      assert is_list(Shem.Cluster.nodes())
    end
  end

  describe "GenServer lifecycle" do
    test "starts and stops cleanly" do
      {:ok, pid} = Shem.Cluster.start_link([])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "handle_info nodeup/nodedown are handled without crash" do
      {:ok, pid} = Shem.Cluster.start_link([])
      send(pid, {:nodeup, :"fake@127.0.0.1"})
      send(pid, {:nodedown, :"fake@127.0.0.1"})
      Process.sleep(20)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
```

- [ ] **Step 2: Run test to confirm failure**

```bash
mix test test/shem/cluster_test.exs --seed 0
```

Expected: fails — module does not exist.

- [ ] **Step 3: Create lib/shem/cluster.ex**

```elixir
defmodule Shem.Cluster do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec nodes() :: [node()]
  def nodes, do: [Node.self() | Node.list()]

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
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/cluster_test.exs --seed 0
```

Expected: all 4 tests pass.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/cluster.ex test/shem/cluster_test.exs
git commit -m "feat: Shem.Cluster GenServer — node monitoring and nodes/0"
```

---

## Task 5: Horde Registry + Application wiring

Replace the local OTP `Registry` with `Horde.Registry`, update `ProcessRegistry.via_tuple/1`, and wire `Shem.Cluster` + `Cluster.Supervisor` into the application supervision tree.

**Files:**
- Modify: `lib/shem/process_registry.ex`
- Modify: `lib/shem/application.ex`
- Test: `test/shem/process_registry_test.exs`

- [ ] **Step 1: Check the existing process registry test**

```bash
cat test/shem/process_registry_test.exs
```

Note the existing test structure; the tests will continue passing with Horde.

- [ ] **Step 2: Update ProcessRegistry to use Horde.Registry**

Replace the entire content of `lib/shem/process_registry.ex`:

```elixir
defmodule Shem.ProcessRegistry do
  @registry Shem.Registry

  @spec via_tuple(term()) :: {:via, Horde.Registry, {atom(), term()}}
  def via_tuple(name), do: {:via, Horde.Registry, {@registry, name}}
end
```

- [ ] **Step 3: Update Application to use Horde.Registry and add cluster children**

Replace the entire content of `lib/shem/application.ex`:

```elixir
defmodule Shem.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Horde.Registry, [name: Shem.Registry, keys: :unique, members: :auto]},
        Shem.AgentSupervisor,
        Shem.EventLog,
        {Task.Supervisor, name: Shem.Lab.TaskSupervisor},
        Shem.Lab.Registry,
        Shem.LLM.BudgetServer
      ] ++
        llm_stub_children() ++
        mcp_children() ++
        cluster_children() ++
        tui_children()

    opts = [strategy: :one_for_one, name: Shem.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @test_env Mix.env() == :test

  defp llm_stub_children do
    if Application.get_env(:shem, :start_llm_stub, @test_env) do
      [{Shem.LLM.StubTransport.Server, name: Shem.LLM.StubTransport.Server}]
    else
      []
    end
  end

  defp mcp_children do
    if Application.get_env(:shem, :start_mcp, true) do
      [Shem.MCP.Server, Shem.MCP.Client.Supervisor]
    else
      []
    end
  end

  defp cluster_children do
    if Application.get_env(:shem, :start_cluster, true) do
      [
        {Cluster.Supervisor,
         [Application.get_env(:libcluster, :topologies, []), [name: Shem.Cluster.Supervisor]]},
        Shem.Cluster
      ]
    else
      []
    end
  end

  defp tui_children do
    if Application.get_env(:shem, :start_tui, true) do
      [Shem.TUI.RuntimeSupervisor]
    else
      []
    end
  end
end
```

- [ ] **Step 4: Run the full test suite**

```bash
mix test
```

Expected: all tests pass. The registry swap is transparent — `via_tuple` format is the same, Horde.Registry implements the same `:via` callbacks.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/process_registry.ex lib/shem/application.ex
git commit -m "feat: replace OTP Registry with Horde.Registry; add Cluster children to Application"
```

---

## Task 6: Horde AgentSupervisor — session_id generated upstream

Switch `Shem.AgentSupervisor` to use `Horde.DynamicSupervisor`. Generate `session_id` in `start_agent/2` so the child spec carries it — enabling Horde to pass it through on redistribution.

**Files:**
- Modify: `lib/shem/agent_supervisor.ex`
- Modify: `test/shem/agent_supervisor_test.exs`

- [ ] **Step 1: Update AgentSupervisor**

Replace the entire content of `lib/shem/agent_supervisor.ex`:

```elixir
defmodule Shem.AgentSupervisor do
  use Horde.DynamicSupervisor

  alias Shem.Agent.Config

  def start_link(init_arg) do
    Horde.DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    Horde.DynamicSupervisor.init(strategy: :one_for_one, members: :auto)
  end

  @spec start_agent(String.t(), Config.t()) :: Horde.DynamicSupervisor.on_start_child()
  def start_agent(name, %Config{} = config) do
    session_id = generate_session_id()
    via = Shem.ProcessRegistry.via_tuple(name)

    child_spec = %{
      id: name,
      start: {Shem.Agent.Server, :start_link, [{name, config, session_id, [name: via]}]},
      restart: :temporary
    }

    Horde.DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  defp generate_session_id do
    "ses_" <> Base.encode16(:crypto.strong_rand_bytes(8))
  end
end
```

- [ ] **Step 2: Update the agent_supervisor_test to expect the new no-restart behavior with Horde**

Horde's registry cleanup after process exit is asynchronous. Bump the sleep in the "not restarted" test. Replace the full file content of `test/shem/agent_supervisor_test.exs`:

```elixir
defmodule Shem.AgentSupervisorTest do
  use ExUnit.Case, async: false

  alias Shem.{Agent, AgentSupervisor}

  setup do
    Shem.LLM.BudgetServer.reset()
    Shem.LLM.StubTransport.Server.reset()
    lab_dir = Application.get_env(:shem, :lab_dir)
    on_exit(fn ->
      File.rm_rf!(lab_dir)
      Shem.Lab.Registry.flush()
    end)
    :ok
  end

  test "start_agent/2 starts a live Agent.Server process" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    config = %Agent.Config{task: "t", system_prompt: "s"}
    name = "test_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = AgentSupervisor.start_agent(name, config)
    assert Process.alive?(pid)
  end

  test "started agent registers in Shem.Registry under its name" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    config = %Agent.Config{task: "t", system_prompt: "s"}
    name = "test_agent_#{System.unique_integer([:positive])}"
    AgentSupervisor.start_agent(name, config)
    via = Shem.ProcessRegistry.via_tuple(name)
    assert is_pid(GenServer.whereis(via))
  end

  test "a crashed agent is NOT restarted (:temporary restart strategy)" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    config = %Agent.Config{task: "t", system_prompt: "s"}
    name = "test_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = AgentSupervisor.start_agent(name, config)
    Process.exit(pid, :kill)
    # Horde registry cleanup is async — give it time
    Process.sleep(300)
    via = Shem.ProcessRegistry.via_tuple(name)
    assert GenServer.whereis(via) == nil
  end
end
```

- [ ] **Step 3: Run tests — expect Agent.Server tests to fail (signature mismatch)**

```bash
mix test test/shem/agent_supervisor_test.exs test/shem/agent/server_test.exs --seed 0
```

Expected: `AgentSupervisorTest` passes; `ServerTest` fails because `Agent.Server.start_link/1` still expects `{name, config, opts}` but now receives `{name, config, session_id, opts}`. This is expected — fixed in Task 7.

- [ ] **Step 4: Commit**

```bash
git add lib/shem/agent_supervisor.ex test/shem/agent_supervisor_test.exs
git commit -m "feat: AgentSupervisor — Horde.DynamicSupervisor, session_id generated upstream"
```

---

## Task 7: Agent.Server — checkpoint integration and resume

Update `Agent.Server` to accept the `session_id` from its args, save a checkpoint before each turn, and resume from checkpoint on init when one exists.

**Files:**
- Modify: `lib/shem/agent/server.ex`
- Modify: `test/shem/agent/server_test.exs`

- [ ] **Step 1: Update Agent.Server**

Replace the entire content of `lib/shem/agent/server.ex`:

```elixir
defmodule Shem.Agent.Server do
  use GenServer

  alias Shem.Agent.{Config, Turn, ToolDispatch, Checkpoint}
  alias Shem.{EventLog, LLM}

  def start_link({name, %Config{} = config, session_id, opts}) do
    GenServer.start_link(__MODULE__, {name, config, session_id}, opts)
  end

  # ── Client API ──────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, state.status}, state}
  end

  def handle_call(:await, _from, %{status: s} = state) when s in [:done, :error] do
    {:reply, {:ok, s}, state}
  end

  def handle_call(:await, from, state) do
    {:noreply, %{state | awaiting: [from | state.awaiting]}}
  end

  def handle_call(:session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  # ── Init ────────────────────────────────────────────────────────────────────

  @impl true
  def init({name, config, session_id}) do
    {:ok, ^session_id} = EventLog.start_session(session_id)

    {history, turn_count} =
      case Checkpoint.reconstruct(session_id) do
        :not_found ->
          EventLog.append(session_id, :agent_started, %{
            task: config.task,
            model: config.model,
            max_turns: config.max_turns
          })
          {[%{role: :user, content: config.task}], 0}

        {:ok, checkpoint} ->
          EventLog.append(session_id, :agent_resumed, %{
            node: Node.self(),
            turn: checkpoint.turn_count
          })
          {checkpoint.history, checkpoint.turn_count}
      end

    state = %{
      name: name,
      config: config,
      history: history,
      session_id: session_id,
      turn_count: turn_count,
      status: :running,
      done_reason: nil,
      awaiting: []
    }

    send(self(), :run_turn)
    {:ok, state}
  end

  # ── Loop ────────────────────────────────────────────────────────────────────

  @impl true
  def handle_info(:run_turn, %{status: s} = state) when s != :running do
    {:noreply, state}
  end

  def handle_info(:run_turn, state) do
    Checkpoint.save(state.session_id, state)

    cond do
      state.turn_count >= state.config.max_turns ->
        {:noreply, finish(state, :done, :max_turns_reached)}

      LLM.BudgetServer.check() == {:error, :budget_exhausted} ->
        {:noreply, finish(state, :done, :budget_exhausted)}

      true ->
        EventLog.append(state.session_id, :agent_turn_started, %{turn: state.turn_count + 1})
        manifest = ToolDispatch.build_manifest(state.config)

        case Turn.step(state.config, state.session_id, state.history, manifest) do
          {:done, answer} ->
            history = state.history ++ [%{role: :assistant, content: answer}]
            EventLog.append(state.session_id, :agent_turn_completed, %{
              turn: state.turn_count + 1,
              outcome: :done
            })
            {:noreply,
             finish(%{state | history: history, turn_count: state.turn_count + 1}, :done, :answer)}

          {:tool_calls, calls, raw} ->
            history = state.history ++ [%{role: :assistant, content: raw}]
            history = execute_tool_calls(calls, manifest, history, state.session_id)
            EventLog.append(state.session_id, :agent_turn_completed, %{
              turn: state.turn_count + 1,
              outcome: :tool_calls
            })
            new_state = %{state | history: history, turn_count: state.turn_count + 1}
            send(self(), :run_turn)
            {:noreply, new_state}

          {:error, reason} ->
            EventLog.append(state.session_id, :agent_error, %{reason: inspect(reason)})
            {:noreply, finish(state, :error, reason)}
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp execute_tool_calls(calls, manifest, history, session_id) do
    Enum.reduce(calls, history, fn call, acc ->
      EventLog.append(session_id, :agent_tool_called, %{tool: call.tool, args: call.args})

      result_str =
        case ToolDispatch.execute(call, manifest) do
          {:ok, result} -> result
          {:error, reason} -> "Error: #{reason}"
        end

      EventLog.append(session_id, :agent_tool_result, %{tool: call.tool, result: result_str})
      acc ++ [%{role: :tool, content: "Tool result (#{call.tool}): #{result_str}"}]
    end)
  end

  defp finish(state, status, reason) do
    EventLog.append(state.session_id, :agent_done, %{reason: reason})
    Enum.each(state.awaiting, fn from -> GenServer.reply(from, {:ok, status}) end)
    %{state | status: status, done_reason: reason, awaiting: []}
  end
end
```

- [ ] **Step 2: Run the server tests to see current failures**

```bash
mix test test/shem/agent/server_test.exs --seed 0
```

Expected: failures related to EventLog finding existing sessions (each test run now re-opens the session). Look for any failures.

- [ ] **Step 3: Add checkpoint and resume tests to server_test.exs**

Open `test/shem/agent/server_test.exs` and add a new describe block before the final `end`:

```elixir
describe "checkpoint and resume" do
  test "a checkpoint is written before each turn" do
    {:ok, sessions_before} = Shem.EventLog.list_sessions()
    before_ids = MapSet.new(Enum.map(sessions_before, & &1.id))

    stub("done")
    name = start_agent("task")
    Agent.await(name, 2_000)

    {:ok, sessions_after} = Shem.EventLog.list_sessions()
    session = Enum.find(sessions_after, fn s -> s.id not in before_ids end)
    assert session != nil

    session_id = GenServer.call(Shem.ProcessRegistry.via_tuple(name), :session_id)
    {:ok, events} = Shem.EventLog.events(session_id)
    checkpoint_events = Enum.filter(events, &(&1.type == :agent_checkpoint))
    assert length(checkpoint_events) >= 1
  end

  test "agent resumes from checkpoint when session already has a checkpoint" do
    # Open a session manually, save a checkpoint, then start an agent with that session_id
    session_id = "ses_RESUME_TEST_" <> Base.encode16(:crypto.strong_rand_bytes(4))
    {:ok, ^session_id} = Shem.EventLog.start_session(session_id)

    prior_history = [
      %{role: :user, content: "resume task"},
      %{role: :assistant, content: "I'll help"},
      %{role: :tool, content: "Tool result (list_tools): []"}
    ]
    config = %Agent.Config{task: "resume task", system_prompt: "helpful", max_turns: 10}

    Shem.Agent.Checkpoint.save(session_id, %{
      history: prior_history,
      turn_count: 3,
      config: config
    })

    # Start Agent.Server directly with the pre-seeded session_id
    name = "resume_agent_#{System.unique_integer([:positive])}"
    stub("Final answer after resume.")
    via = Shem.ProcessRegistry.via_tuple(name)
    child_spec = %{
      id: name,
      start: {Shem.Agent.Server, :start_link, [{name, config, session_id, [name: via]}]},
      restart: :temporary
    }
    {:ok, _pid} = Horde.DynamicSupervisor.start_child(Shem.AgentSupervisor, child_spec)
    assert {:ok, :done} = Agent.await(name, 2_000)

    # Verify :agent_resumed was appended
    {:ok, events} = Shem.EventLog.events(session_id)
    assert Enum.any?(events, &(&1.type == :agent_resumed))
  end
end
```

- [ ] **Step 4: Run all agent tests**

```bash
mix test test/shem/agent/ --seed 0
```

Expected: all agent tests pass.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/agent/server.ex test/shem/agent/server_test.exs
git commit -m "feat: Agent.Server — session_id from args, checkpoint before each turn, resume from checkpoint"
```

---

## Task 8: BudgetServer — per-node token budget

Add `budget_node_tokens` config key. When set, it takes precedence over `llm_budget_limit` as the effective limit for this node.

**Files:**
- Modify: `lib/shem/llm/budget_server.ex`
- Test: `test/shem/llm_test.exs` (BudgetServer section) or a new file if one exists

- [ ] **Step 1: Find the BudgetServer test**

```bash
grep -r "BudgetServer" test/ --include="*.exs" -l
```

Note the file; add tests there.

- [ ] **Step 2: Write the failing test**

In the file found above, add to the BudgetServer describe block:

```elixir
test "reads budget_node_tokens when set, ignoring llm_budget_limit" do
  Application.put_env(:shem, :budget_node_tokens, 999)
  on_exit(fn -> Application.delete_env(:shem, :budget_node_tokens) end)
  {:ok, pid} = Shem.LLM.BudgetServer.start_link(name: :test_node_budget)
  status = Shem.LLM.BudgetServer.status(:test_node_budget)
  assert status.global_limit == 999
  GenServer.stop(:test_node_budget)
end

test "falls back to llm_budget_limit when budget_node_tokens is not set" do
  Application.delete_env(:shem, :budget_node_tokens)
  {:ok, pid} = Shem.LLM.BudgetServer.start_link(name: :test_fallback_budget, limit: 12_345)
  status = Shem.LLM.BudgetServer.status(:test_fallback_budget)
  assert status.global_limit == 12_345
  GenServer.stop(:test_fallback_budget)
end
```

- [ ] **Step 3: Run test to confirm failure**

```bash
mix test --seed 0 -k "budget_node_tokens"
```

Expected: fails — `start_link` doesn't read `budget_node_tokens`.

- [ ] **Step 4: Update BudgetServer.start_link/1**

In `lib/shem/llm/budget_server.ex`, replace the `start_link/1` function:

```elixir
def start_link(opts \\ []) do
  name = Keyword.get(opts, :name, __MODULE__)

  limit =
    Keyword.get(
      opts,
      :limit,
      Application.get_env(
        :shem,
        :budget_node_tokens,
        Application.get_env(:shem, :llm_budget_limit, 500_000)
      )
    )

  threshold =
    Keyword.get(opts, :soft_threshold, Application.get_env(:shem, :llm_soft_threshold, 0.8))

  GenServer.start_link(__MODULE__, {limit, threshold}, name: name)
end
```

- [ ] **Step 5: Run tests**

```bash
mix test --seed 0
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/llm/budget_server.ex
git commit -m "feat: BudgetServer reads budget_node_tokens for per-node limit"
```

---

## Task 9: Lab.Executor remote dispatch + GraduationGate wiring

Add `node:` option to `Executor.run/3`. When set, dispatches via `:rpc.call/5`. `GraduationGate` reads `lab_executor_node` from config and passes it through.

**Files:**
- Modify: `lib/shem/lab/executor.ex`
- Modify: `lib/shem/lab/graduation_gate.ex`
- Test: `test/shem/lab/` (executor tests)

- [ ] **Step 1: Find executor tests**

```bash
ls test/shem/lab/
```

- [ ] **Step 2: Write the failing tests**

In `test/shem/lab/executor_test.exs`, add:

```elixir
describe "remote node dispatch" do
  test "node: nil uses local execution (existing behavior)" do
    source = """
    defmodule RemoteTestLocal do
      def run, do: :local_result
    end
    """
    assert {:ok, :local_result} = Shem.Lab.Executor.run(source, fn m -> m.run() end, node: nil)
  end

  test "node: Node.self() uses local execution" do
    source = """
    defmodule RemoteTestSelf do
      def run, do: :self_result
    end
    """
    assert {:ok, :self_result} =
             Shem.Lab.Executor.run(source, fn m -> m.run() end, node: Node.self())
  end

  test "node: :nonexistent@host returns {:error, :nodedown} or similar" do
    source = "defmodule RemoteTestFail do\n  def run, do: :ok\nend"
    result = Shem.Lab.Executor.run(source, fn m -> m.run() end, node: :"nonexistent@127.0.0.1")
    assert match?({:error, _}, result)
  end
end
```

- [ ] **Step 3: Run test to confirm failure on remote test**

```bash
mix test test/shem/lab/executor_test.exs --seed 0
```

Expected: `node: nil` and `node: Node.self()` tests fail (option not yet supported); the nonexistent node test also fails.

- [ ] **Step 4: Update Executor to support node: option**

Replace the entire content of `lib/shem/lab/executor.ex`:

```elixir
defmodule Shem.Lab.Executor do
  @default_timeout 5_000

  @spec run(String.t(), (atom() -> any()), keyword()) ::
          {:ok, any()}
          | {:error, :compile, String.t()}
          | {:error, :timeout}
          | {:error, :runtime, any()}
          | {:error, any()}
  def run(source, fun, opts \\ []) do
    timeout =
      Keyword.get(opts, :timeout, Application.get_env(:shem, :executor_timeout_ms, @default_timeout))

    target_node = Keyword.get(opts, :node, nil)

    if target_node && target_node != Node.self() do
      run_remote(source, fun, timeout, target_node)
    else
      run_local(source, fun, timeout)
    end
  end

  defp run_remote(source, fun, timeout, node) do
    case :rpc.call(node, __MODULE__, :run, [source, fun, [timeout: timeout]], timeout + 1_000) do
      {:badrpc, reason} -> {:error, reason}
      result -> result
    end
  end

  defp run_local(source, fun, timeout) do
    case compile(source) do
      {:ok, modules} ->
        Enum.each(modules, fn {mod, bc} -> :code.load_binary(mod, ~c"nofile", bc) end)
        last_module = modules |> List.last() |> elem(0)

        try do
          execute(last_module, fun, timeout)
        after
          Enum.each(modules, fn {mod, _} ->
            :code.purge(mod)
            :code.delete(mod)
          end)
        end

      error ->
        error
    end
  end

  defp compile(source) do
    try do
      case Code.compile_string(source) do
        [] -> {:error, :compile, "source defines no modules"}
        modules -> {:ok, modules}
      end
    rescue
      e -> {:error, :compile, Exception.message(e)}
    end
  end

  defp execute(module, fun, timeout) do
    task = Task.Supervisor.async_nolink(Shem.Lab.TaskSupervisor, fn -> fun.(module) end)

    case Task.yield(task, timeout) do
      {:ok, value} ->
        {:ok, value}

      {:exit, reason} ->
        {:error, :runtime, reason}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end
end
```

- [ ] **Step 5: Update GraduationGate to pass lab_executor_node**

In `lib/shem/lab/graduation_gate.ex`, replace the entire `run/3` function with:

```elixir
def run(source, test_source, constraints \\ []) do
  combined = source <> "\n" <> test_source

  executor_opts =
    case Application.get_env(:shem, :lab_executor_node) do
      nil -> []
      node -> [node: node]
    end

  case Executor.run(combined, fn test_mod -> test_mod.run() end, executor_opts) do
    {:ok, :ok} ->
      with {:ok, module} <- extract_module(source) do
        id = unique_id(module)
        tool = %Tool{
          id: id,
          name: module |> Atom.to_string() |> String.split(".") |> List.last(),
          module: module,
          source: source,
          test_source: test_source,
          constraints: constraints,
          graduated_at: DateTime.utc_now(),
          metadata: %{}
        }
        :ok = Workspace.graduate(tool)
        :ok = Registry.register(tool)
        {:ok, tool}
      else
        {:error, :compile, reason} -> {:error, :compile, reason}
      end

    {:error, :compile, reason} ->
      {:error, :compile, reason}

    {:error, :runtime, reason} ->
      {:error, :gate, reason}

    {:error, :timeout} ->
      {:error, :timeout}
  end
end
```

- [ ] **Step 6: Run executor tests**

```bash
mix test test/shem/lab/executor_test.exs --seed 0
```

Expected: all pass. The nonexistent-node test passes because `:rpc.call` returns `{:badrpc, :nodedown}` which normalises to `{:error, :nodedown}`.

- [ ] **Step 7: Run full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add lib/shem/lab/executor.ex lib/shem/lab/graduation_gate.ex test/shem/lab/executor_test.exs
git commit -m "feat: Lab.Executor remote node dispatch via :rpc.call; GraduationGate wired to lab_executor_node config"
```

---

## Task 10: TUI — Cluster node count

Add `cluster_node_count` to the TUI model, update it in the 500ms tick, and display `Cluster: N nodes` in the Dashboard.

**Files:**
- Modify: `lib/shem/tui/app.ex`
- Modify: `lib/shem/tui/views/dashboard.ex`

- [ ] **Step 1: Update TUI.App — add cluster_node_count to model and tick**

In `lib/shem/tui/app.ex`, update `init/1` to add the new field:

```elixir
@impl true
def init(_context) do
  %{
    mode: :dashboard,
    command_buffer: "",
    paused: false,
    event_log_stats: %{sessions: 0, total_events: 0},
    tool_count: 0,
    mcp_client_count: 0,
    mcp_outbound_count: 0,
    cluster_node_count: 1
  }
end
```

Update the `:tick` branch in `update/2`:

```elixir
:tick ->
  %{
    model
    | event_log_stats: safe_stats(),
      tool_count: safe_tool_count(),
      mcp_client_count: safe_mcp_count(),
      mcp_outbound_count: safe_mcp_outbound_count(),
      cluster_node_count: safe_cluster_count()
  }
```

Add the private function at the bottom of the module (before the final `end`):

```elixir
defp safe_cluster_count do
  try do
    Shem.Cluster.nodes() |> length()
  catch
    :exit, _ -> 1
  end
end
```

- [ ] **Step 2: Update Dashboard view to show cluster count**

In `lib/shem/tui/views/dashboard.ex`, inside the `panel(title: "Lab Status", ...)` block, add a new label after the MCP clients line:

```elixir
label(
  content: "Cluster: #{model.cluster_node_count} #{if model.cluster_node_count == 1, do: "node", else: "nodes"}",
  color: color(:cyan)
)
```

The full updated panel block becomes:

```elixir
column(size: 4) do
  panel(title: "Lab Status", color: color(:magenta)) do
    label(content: "Tools graduated: #{model.tool_count}", color: color(:white))

    label(
      content:
        "MCP: localhost:#{Application.get_env(:shem, :mcp_port, 4000)} — #{model.mcp_client_count} connected",
      color: color(:cyan)
    )

    label(
      content: "MCP clients: #{model.mcp_outbound_count} connected",
      color: color(:cyan)
    )

    label(
      content: "Cluster: #{model.cluster_node_count} #{if model.cluster_node_count == 1, do: "node", else: "nodes"}",
      color: color(:cyan)
    )

    label(
      content:
        "Sessions: #{model.event_log_stats.sessions}   Events: #{model.event_log_stats.total_events}",
      color: color(:white)
    )

    label(content: "")

    label(
      content: "Lab: idle",
      attributes: [attribute(:bold)],
      color: color(:magenta)
    )
  end
end
```

- [ ] **Step 3: Run the full test suite**

```bash
mix test
```

Expected: all tests pass. TUI tests (if any) should still pass since `cluster_node_count` defaults to `1`.

- [ ] **Step 4: Commit**

```bash
git add lib/shem/tui/app.ex lib/shem/tui/views/dashboard.ex
git commit -m "feat: TUI Dashboard shows Cluster: N nodes"
```

---

## Done

All 10 tasks complete. Run the final suite to confirm the full build:

```bash
mix test
```

Expected: all tests pass (≥ 306 + new tests for Checkpoint, Cluster, EventLog, Executor, Agent resume ≈ ~340+).
