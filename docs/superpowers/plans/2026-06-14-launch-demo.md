# Launch Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `mix demo` — a self-contained ~90-second demo that proves distributed agent mesh, node failure recovery, time-travel scrub+fork, and adversarial hardening, all driven by stubbed LLM responses with no external services.

**Architecture:** Four phases run sequentially inside a single Mix task; real `:peer` BEAM nodes provide genuine distribution; `EventLog.scrub/2` (new) and `LLM.Branch.branch_after_call/4` (existing) power Phase 3; `HardeningJob` (existing) drives Phase 4 with scripted stub responses; per-node `StubTransport.Server` instances handle cross-node LLM calls correctly.

**Tech Stack:** Elixir/OTP, Horde, `:peer` (Erlang 25+), MnesiaStore, StubTransport, EventLog, HardeningJob, Trust.Store

**Spec:** `docs/superpowers/specs/2026-06-14-launch-demo-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `lib/shem/event_log/store.ex` | Modify | Add `scrub/2` callback |
| `lib/shem/event_log/fake_store.ex` | Modify | Implement `scrub/2` via ETS delete |
| `lib/shem/event_log/dets_store.ex` | Modify | Implement `scrub/2` via `:dets.delete` |
| `lib/shem/event_log/mnesia_store.ex` | Modify | Implement `scrub/2` via `:mnesia.dirty_delete` |
| `lib/shem/event_log.ex` | Modify | Add `scrub/2` public API + GenServer handler |
| `test/shem/event_log_test.exs` | Modify | Add `scrub/2` tests (FakeStore + DETSStore) |
| `test/shem/distributed/event_log_test.exs` | Modify | Add `scrub/2` test for MnesiaStore |
| `lib/shem/adversarial/hardening_job.ex` | Modify | Read `adversarial_agent_placement` env in agent configs |
| `lib/mix/tasks/demo.ex` | Create | Full `mix demo` Mix task |

---

### Task 1: EventLog.scrub/2 — Store behaviour + FakeStore + public API

**Files:**
- Modify: `lib/shem/event_log/store.ex`
- Modify: `lib/shem/event_log/fake_store.ex`
- Modify: `lib/shem/event_log.ex`
- Test: `test/shem/event_log_test.exs`

- [ ] **Step 1: Write failing tests**

Add this `describe` block to `test/shem/event_log_test.exs`, before the final `end`:

```elixir
describe "scrub/2" do
  test "removes events after the pivot ID, keeping pivot" do
    {:ok, sid} = EventLog.start_session()
    EventLog.append(sid, :evt_a, %{})
    EventLog.append(sid, :evt_b, %{})
    EventLog.append(sid, :evt_c, %{})
    {:ok, [a, b, _c]} = EventLog.events(sid)

    :ok = EventLog.scrub(sid, b.id)

    {:ok, remaining} = EventLog.events(sid)
    assert length(remaining) == 2
    assert Enum.any?(remaining, &(&1.id == a.id))
    assert Enum.any?(remaining, &(&1.id == b.id))
    refute Enum.any?(remaining, &(&1.type == :evt_c))
  end

  test "scrubbing the last event ID is a no-op" do
    {:ok, sid} = EventLog.start_session()
    EventLog.append(sid, :evt_a, %{})
    {:ok, [a]} = EventLog.events(sid)

    :ok = EventLog.scrub(sid, a.id)

    {:ok, remaining} = EventLog.events(sid)
    assert length(remaining) == 1
  end

  test "scrubbing the first event ID removes all after it" do
    {:ok, sid} = EventLog.start_session()
    EventLog.append(sid, :evt_a, %{})
    EventLog.append(sid, :evt_b, %{})
    EventLog.append(sid, :evt_c, %{})
    {:ok, [a | _]} = EventLog.events(sid)

    :ok = EventLog.scrub(sid, a.id)

    {:ok, remaining} = EventLog.events(sid)
    assert length(remaining) == 1
    assert hd(remaining).type == :evt_a
  end

  test "returns {:error, :session_not_found} for unknown session" do
    assert {:error, :session_not_found} = EventLog.scrub("ses_no_such", "evt_x")
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd /home/philip/Downloads/_project/shem
mix test test/shem/event_log_test.exs --only "scrub" 2>&1 | tail -20
```

Expected: `** (UndefinedFunctionError) function EventLog.scrub/2 is undefined`

- [ ] **Step 3: Add `scrub/2` callback to Store behaviour**

In `lib/shem/event_log/store.ex`, add after the `close/1` callback:

```elixir
@callback scrub(handle :: term(), after_event_id :: String.t()) ::
            :ok | {:error, :event_not_found}
```

- [ ] **Step 4: Implement `scrub/2` in FakeStore**

In `lib/shem/event_log/fake_store.ex`, add after `close/1`:

```elixir
@impl true
def scrub(table, after_event_id) do
  {:ok, events} = read_all(table)

  case Enum.find_index(events, &(&1.id == after_event_id)) do
    nil ->
      {:error, :event_not_found}

    cut_index ->
      events
      |> Enum.drop(cut_index + 1)
      |> Enum.each(fn event -> :ets.delete(table, event.id) end)

      :ok
  end
end
```

- [ ] **Step 5: Add `scrub/2` to EventLog public API**

In `lib/shem/event_log.ex`, add after the `events/1` spec + def:

```elixir
@spec scrub(String.t(), String.t()) ::
        :ok | {:error, :session_not_found | :session_ended | :event_not_found}
def scrub(session_id, after_event_id),
  do: GenServer.call(__MODULE__, {:scrub, session_id, after_event_id})
```

- [ ] **Step 6: Add GenServer handler for `scrub/2`**

In `lib/shem/event_log.ex`, add after the `handle_call({:events, ...}, ...)` clause:

```elixir
@impl true
def handle_call({:scrub, session_id, after_event_id}, _from, state) do
  case get_active_handle(state, session_id) do
    {:ok, handle} -> {:reply, state.store.scrub(handle, after_event_id), state}
    error -> {:reply, error, state}
  end
end
```

- [ ] **Step 7: Run tests and confirm they pass**

```bash
mix test test/shem/event_log_test.exs 2>&1 | tail -10
```

Expected: all existing tests pass plus the 4 new `scrub/2` tests.

- [ ] **Step 8: Commit**

```bash
git add lib/shem/event_log/store.ex lib/shem/event_log/fake_store.ex lib/shem/event_log.ex test/shem/event_log_test.exs
git commit -m "feat: add EventLog.scrub/2 — delete events after pivot ID"
```

---

### Task 2: EventLog.scrub/2 — DETSStore

**Files:**
- Modify: `lib/shem/event_log/dets_store.ex`
- Test: `test/shem/event_log_test.exs`

- [ ] **Step 1: Write failing DETSStore scrub test**

Add this `describe` block to `test/shem/event_log_test.exs`, after the `scrub/2` describe block:

```elixir
describe "scrub/2 (DETSStore)" do
  setup do
    Application.put_env(:shem, :event_log_store, Shem.EventLog.DETSStore)
    Supervisor.terminate_child(Shem.Supervisor, Shem.EventLog)
    Supervisor.restart_child(Shem.Supervisor, Shem.EventLog)

    on_exit(fn ->
      Application.put_env(:shem, :event_log_store, Shem.EventLog.FakeStore)
      Supervisor.terminate_child(Shem.Supervisor, Shem.EventLog)
      Supervisor.restart_child(Shem.Supervisor, Shem.EventLog)
    end)

    :ok
  end

  test "removes events after the pivot ID in DETS" do
    {:ok, sid} = EventLog.start_session()
    EventLog.append(sid, :d_a, %{})
    EventLog.append(sid, :d_b, %{})
    EventLog.append(sid, :d_c, %{})
    {:ok, [a, b, _c]} = EventLog.events(sid)

    :ok = EventLog.scrub(sid, b.id)

    {:ok, remaining} = EventLog.events(sid)
    assert length(remaining) == 2
    assert Enum.any?(remaining, &(&1.id == a.id))
    assert Enum.any?(remaining, &(&1.id == b.id))
    refute Enum.any?(remaining, &(&1.type == :d_c))
  end
end
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
mix test test/shem/event_log_test.exs --only "DETSStore" 2>&1 | tail -10
```

Expected: `** (UndefinedFunctionError)` — `DETSStore.scrub/2` not defined.

- [ ] **Step 3: Implement `scrub/2` in DETSStore**

In `lib/shem/event_log/dets_store.ex`, add after `close/1`:

```elixir
@impl true
def scrub(table, after_event_id) do
  {:ok, events} = read_all(table)

  case Enum.find_index(events, &(&1.id == after_event_id)) do
    nil ->
      {:error, :event_not_found}

    cut_index ->
      events
      |> Enum.drop(cut_index + 1)
      |> Enum.each(fn event -> :dets.delete(table, event.id) end)

      :ok
  end
end
```

- [ ] **Step 4: Run tests and confirm they pass**

```bash
mix test test/shem/event_log_test.exs 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/event_log/dets_store.ex test/shem/event_log_test.exs
git commit -m "feat: implement EventLog.scrub/2 in DETSStore"
```

---

### Task 3: EventLog.scrub/2 — MnesiaStore

**Files:**
- Modify: `lib/shem/event_log/mnesia_store.ex`
- Test: `test/shem/distributed/event_log_test.exs`

- [ ] **Step 1: Implement `scrub/2` in MnesiaStore**

In `lib/shem/event_log/mnesia_store.ex`, add after `close/1`:

```elixir
@impl true
def scrub(session_id, after_event_id) do
  {:ok, events} = read_all(session_id)

  case Enum.find_index(events, &(&1.id == after_event_id)) do
    nil ->
      {:error, :event_not_found}

    cut_index ->
      events
      |> Enum.drop(cut_index + 1)
      |> Enum.each(fn event ->
        :mnesia.dirty_delete(@table, {session_id, event.id})
      end)

      :ok
  end
end
```

- [ ] **Step 2: Add a distributed scrub test**

Open `test/shem/distributed/event_log_test.exs`. Find the last test in the file and add after it (before the final `end`):

```elixir
test "scrub/2 removes events after pivot in Mnesia" do
  {:ok, sid} = Shem.EventLog.start_session()
  Shem.EventLog.append(sid, :m_a, %{})
  Shem.EventLog.append(sid, :m_b, %{})
  Shem.EventLog.append(sid, :m_c, %{})
  {:ok, [a, b, _c]} = Shem.EventLog.events(sid)

  :ok = Shem.EventLog.scrub(sid, b.id)

  {:ok, remaining} = Shem.EventLog.events(sid)
  assert length(remaining) == 2
  assert Enum.any?(remaining, &(&1.id == a.id))
  assert Enum.any?(remaining, &(&1.id == b.id))
  refute Enum.any?(remaining, &(&1.type == :m_c))
end
```

- [ ] **Step 3: Run distributed tests**

```bash
elixir --sname shem_test -S mix test --only distributed 2>&1 | tail -15
```

Expected: all distributed tests pass including the new scrub test.

- [ ] **Step 4: Run full non-distributed suite to verify no regressions**

```bash
mix test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/event_log/mnesia_store.ex test/shem/distributed/event_log_test.exs
git commit -m "feat: implement EventLog.scrub/2 in MnesiaStore; add distributed test"
```

---

### Task 4: HardeningJob — adversarial_agent_placement env

**Files:**
- Modify: `lib/shem/adversarial/hardening_job.ex`

- [ ] **Step 1: Update `red_team_config/1` to read placement env**

In `lib/shem/adversarial/hardening_job.ex`, replace the `red_team_config/1` function:

```elixir
defp red_team_config(tool) do
  %Config{
    task: "Find failures in #{tool.name}",
    system_prompt: """
    You are a red team agent. Your job is to find failures in the Elixir tool "#{tool.name}".
    Source:
    #{tool.source}

    Write StreamData property tests and targeted edge case tests using run_code.
    Each test must call the tool's run/1 function directly.

    When done, respond with exactly one of:
    FAILURES_FOUND: <one-line summary of what broke>
    NO_FAILURES_FOUND
    """,
    tools: ["run_code", "read_file"],
    max_turns: 10,
    placement: Application.get_env(:shem, :adversarial_agent_placement, :any)
  }
end
```

- [ ] **Step 2: Update `target_config/2` to read placement env**

In `lib/shem/adversarial/hardening_job.ex`, replace the `target_config/2` function:

```elixir
defp target_config(tool, failure_summary) do
  %Config{
    task: "Fix #{tool.name}",
    system_prompt: """
    You are a tool repair agent. The tool "#{tool.name}" has a known failure:
    #{failure_summary}

    Current source:
    #{tool.source}

    Rewrite the tool to fix this failure. Use write_tool to graduate the new version.
    The new version must pass its own tests before graduating.
    """,
    tools: ["write_tool", "run_code"],
    max_turns: 10,
    placement: Application.get_env(:shem, :adversarial_agent_placement, :any)
  }
end
```

- [ ] **Step 3: Run the test suite to verify no regressions**

```bash
mix test 2>&1 | tail -10
```

Expected: all tests pass (this is a non-breaking config-driven change).

- [ ] **Step 4: Commit**

```bash
git add lib/shem/adversarial/hardening_job.ex
git commit -m "feat: HardeningJob reads adversarial_agent_placement env for Config.placement"
```

---

### Task 5: Demo task — skeleton, helpers, peer startup

**Files:**
- Create: `lib/mix/tasks/demo.ex`

- [ ] **Step 1: Create the file with skeleton and ANSI helpers**

Create `lib/mix/tasks/demo.ex`:

```elixir
defmodule Mix.Tasks.Demo do
  use Mix.Task

  @shortdoc "Run the Shem launch demo (~90s)"
  @moduledoc """
  Runs the Shem launch demo: four phases proving distributed agents,
  node failure recovery, time-travel debugging, and adversarial hardening.

      elixir --sname shem_demo -S mix demo
  """

  alias Shem.LLM.StubTransport.Server, as: StubServer
  alias Shem.Agent.Config
  alias Shem.{Agent, EventLog, Lab, LLM}

  @impl Mix.Task
  def run(_args) do
    guard_distribution!()
    configure_app()
    Mix.Task.run("app.start", [])
    local_stub = ensure_local_stub()

    banner("SHEM LAUNCH DEMO")
    IO.puts("")

    state = %{local_stub: local_stub}
    state = phase_1(state)
    state = phase_2(state)
    state = phase_3(state)
    phase_4(state)

    IO.puts(
      IO.ANSI.bright() <>
        IO.ANSI.green() <>
        """

        ═══════════════════════════════════════════════════════════════
          SHEM LAUNCH DEMO COMPLETE
          Distributed mesh ✓  Node recovery ✓  Time-travel ✓  Self-healing ✓
        ═══════════════════════════════════════════════════════════════
        """ <>
        IO.ANSI.reset()
    )
  end

  # ── ANSI helpers ────────────────────────────────────────────────────────────

  defp banner(text) do
    line = String.duplicate("═", 63)
    IO.puts(IO.ANSI.bright() <> IO.ANSI.cyan() <> "\n#{line}\n  #{text}\n#{line}" <> IO.ANSI.reset())
  end

  defp phase_banner(text) do
    IO.puts("\n" <> IO.ANSI.bright() <> IO.ANSI.yellow() <> "▶ #{text}" <> IO.ANSI.reset())
  end

  defp step(text), do: IO.puts("  " <> text)

  defp ok(text),
    do: IO.puts("  " <> IO.ANSI.green() <> "✓" <> IO.ANSI.reset() <> "  #{text}")

  defp info(text), do: IO.puts("    " <> IO.ANSI.light_black() <> text <> IO.ANSI.reset())

  defp fail!(phase, reason, hint) do
    IO.puts(IO.ANSI.red() <> "\n✗ PHASE #{phase} FAILED: #{inspect(reason)}" <> IO.ANSI.reset())
    IO.puts("  Hint: #{hint}")
    System.halt(1)
  end

  # ── Startup ─────────────────────────────────────────────────────────────────

  defp guard_distribution! do
    unless Node.alive?() do
      IO.puts(IO.ANSI.red() <> "✗ Erlang distribution is not active." <> IO.ANSI.reset())
      IO.puts("  Run with: elixir --sname shem_demo -S mix demo")
      System.halt(1)
    end
  end

  defp configure_app do
    # MnesiaStore so Phase 2 checkpoints survive node death
    Application.delete_env(:shem, :event_log_store)
    Application.put_env(:shem, :force_mnesia, true)

    # Stub pipeline overrides any dev transport before app.start
    Application.put_env(:shem, :llm_pipeline, [
      {Shem.LLM.Middleware.EventLogger, []},
      {Shem.LLM.StubTransport, [server: Shem.LLM.StubTransport.Server]}
    ])
  end

  defp ensure_local_stub do
    case Process.whereis(Shem.LLM.StubTransport.Server) do
      nil ->
        {:ok, pid} = StubServer.start_link(name: Shem.LLM.StubTransport.Server)
        pid

      pid ->
        StubServer.reset(pid)
        pid
    end
  end

  # ── Peer helper ─────────────────────────────────────────────────────────────

  # Starts a peer BEAM node with full ebin paths, Mnesia membership, Horde,
  # and a StubTransport.Server. Returns {peer_ref, peer_node}.
  defp start_peer(short_name) do
    build_path = Mix.Project.build_path()
    elixir_lib = :code.lib_dir(:elixir) |> Path.dirname() |> to_string()

    pa_args =
      (Path.wildcard(Path.join([elixir_lib, "*", "ebin"])) ++
         Path.wildcard(Path.join([build_path, "lib", "*", "ebin"])))
      |> Enum.flat_map(fn p -> [~c"-pa", String.to_charlist(p)] end)

    {:ok, peer, peer_node} = :peer.start(%{name: short_name, args: pa_args})

    :rpc.call(peer_node, :application, :ensure_all_started, [:elixir])
    :rpc.call(peer_node, :application, :ensure_all_started, [:mnesia])

    # Connect Mnesia to this node's cluster
    self_node = Node.self()

    :rpc.call(peer_node, Code, :eval_string, [
      """
      :mnesia.change_config(:extra_db_nodes, [:"#{self_node}"])
      case :mnesia.add_table_copy(:shem_events, node(), :disc_copies) do
        {:atomic, :ok} -> :ok
        {:aborted, {:already_exists, :shem_events, _}} -> :ok
      end
      :mnesia.wait_for_tables([:shem_events], 10_000)
      """
    ])

    # Start Horde + EventLog + StubTransport in a long-lived spawn to avoid
    # link propagation from the :rpc evaluator process (same pattern as tests)
    :rpc.call(peer_node, Code, :eval_string, [
      """
      Application.delete_env(:shem, :event_log_store)
      Application.put_env(:shem, :llm_pipeline, [
        {Shem.LLM.Middleware.EventLogger, []},
        {Shem.LLM.StubTransport, [server: Shem.LLM.StubTransport.Server]}
      ])
      spawn(fn ->
        {:ok, _} = Horde.Registry.start_link(name: Shem.Registry, keys: :unique, members: :auto)
        {:ok, _} = Shem.AgentSupervisor.start_link([])
        {:ok, _} = Shem.NodeRegistry.start_link([])
        {:ok, _} = Shem.EventLog.start_link([])
        {:ok, _} = Shem.Lab.Registry.start_link([])
        {:ok, _} = :pg.start_link(:shem_streams)
        {:ok, _} = Shem.LLM.StubTransport.Server.start_link(name: Shem.LLM.StubTransport.Server)
        Process.sleep(:infinity)
      end)
      :ok
      """
    ])

    # Poll until StubTransport.Server is up on peer
    assert_eventually(
      fn ->
        case :rpc.call(peer_node, Process, :whereis, [Shem.LLM.StubTransport.Server]) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end,
      5_000
    )

    {peer, peer_node}
  end

  # ── assert_eventually ────────────────────────────────────────────────────────

  defp assert_eventually(fun, timeout_ms, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    result =
      Enum.reduce_while(Stream.repeatedly(fn -> :tick end), nil, fn _, _ ->
        if fun.() do
          {:halt, :ok}
        else
          if System.monotonic_time(:millisecond) < deadline do
            Process.sleep(interval_ms)
            {:cont, nil}
          else
            {:halt, :timeout}
          end
        end
      end)

    result == :ok
  end

  # ── phase stubs (filled in Tasks 6–7) ───────────────────────────────────────

  defp phase_1(state), do: state
  defp phase_2(state), do: state
  defp phase_3(state), do: state
  defp phase_4(state), do: state
end
```

- [ ] **Step 2: Verify compilation**

```bash
mix compile 2>&1 | grep -E "error|warning" | head -20
```

Expected: no errors (warnings about unused variables in stub phases are fine).

- [ ] **Step 3: Commit**

```bash
git add lib/mix/tasks/demo.ex
git commit -m "feat: demo task skeleton — startup, peer helper, ANSI helpers"
```

---

### Task 6: Demo task — Phase 1 (Distributed Mesh) and Phase 2 (Node Recovery)

**Files:**
- Modify: `lib/mix/tasks/demo.ex`

- [ ] **Step 1: Implement `phase_1/1`**

Replace the stub `defp phase_1(state), do: state` with:

```elixir
defp phase_1(state) do
  phase_banner("PHASE 1: DISTRIBUTED MESH")

  {peer_b, peer_b_node} =
    try do
      step("Starting peer node shem_b@localhost...")
      r = start_peer(:shem_b)
      ok("shem_b started")
      r
    rescue
      e -> fail!(1, e, "Ensure you ran with: elixir --sname shem_demo -S mix demo")
    end

  {peer_c, peer_c_node} =
    try do
      step("Starting peer node shem_c@localhost...")
      r = start_peer(:shem_c)
      ok("shem_c started")
      r
    rescue
      e -> fail!(1, e, "Ensure you ran with: elixir --sname shem_demo -S mix demo")
    end

  # Wire Horde membership across all 3 nodes
  step("Wiring Horde membership across 3 nodes...")
  all_nodes = [Node.self(), peer_b_node, peer_c_node]

  Horde.Cluster.set_members(
    Shem.AgentSupervisor,
    Enum.map(all_nodes, &{Shem.AgentSupervisor, &1})
  )

  Horde.Cluster.set_members(
    Shem.Registry,
    Enum.map(all_nodes, &{Shem.Registry, &1})
  )

  unless assert_eventually(
           fn ->
             Horde.Cluster.members(Shem.AgentSupervisor)
             |> Enum.count(fn {_, n} -> n in [peer_b_node, peer_c_node] end) == 2
           end,
           8_000
         ) do
    fail!(1, :horde_timeout, "Horde did not see both peers within 8s")
  end

  ok("Horde mesh: #{length(all_nodes)} nodes")
  Process.sleep(500)

  # Load stub responses on each peer — independent queues, no race
  resp = fn content ->
    {:ok,
     %Shem.LLM.Response{content: content, tokens_used: 1, model: :default, latency_ms: 0}}
  end

  :rpc.call(peer_b_node, StubServer, :push_response, [
    Shem.LLM.StubTransport.Server,
    resp.("Scanning task boundaries…")
  ])

  :rpc.call(peer_b_node, StubServer, :push_response, [
    Shem.LLM.StubTransport.Server,
    resp.("Checkpoint written. Awaiting next instruction.")
  ])

  :rpc.call(peer_c_node, StubServer, :set_default, [
    Shem.LLM.StubTransport.Server,
    resp.("Parallel analysis running on shem_c…")
  ])

  step("Spawning worker_alpha → #{peer_b_node}")

  {:ok, alpha_name, _alpha_sid} =
    Agent.start(%Config{
      task: "Analyze distributed task boundaries",
      system_prompt: "You are a distributed analysis agent. Complete each turn and report.",
      max_turns: 2,
      placement: {:node, peer_b_node}
    })

  step("Spawning worker_beta → #{peer_c_node}")

  {:ok, beta_name, _beta_sid} =
    Agent.start(%Config{
      task: "Run parallel analysis",
      system_prompt: "You are a parallel analysis agent. Complete your turn and report.",
      max_turns: 1,
      placement: {:node, peer_c_node}
    })

  # Await both agents
  case Agent.await(alpha_name, 15_000) do
    {:ok, :done} ->
      info("worker_alpha: \"Checkpoint written.\"")

    err ->
      fail!(1, err, "worker_alpha did not complete within 15s")
  end

  case Agent.await(beta_name, 10_000) do
    {:ok, :done} ->
      info("worker_beta: \"Parallel analysis running on shem_c…\"")

    err ->
      fail!(1, err, "worker_beta did not complete within 10s")
  end

  ok("Two agents ran concurrently across three BEAM nodes.")

  Map.merge(state, %{
    peer_b: peer_b,
    peer_b_node: peer_b_node,
    peer_c: peer_c,
    peer_c_node: peer_c_node
  })
end
```

- [ ] **Step 2: Implement `phase_2/1`**

Replace the stub `defp phase_2(state), do: state` with:

```elixir
defp phase_2(%{peer_b: peer_b, peer_b_node: peer_b_node, peer_c_node: peer_c_node} = state) do
  phase_banner("PHASE 2: NODE FAILURE + RECOVERY")

  resp = fn content ->
    {:ok,
     %Shem.LLM.Response{content: content, tokens_used: 1, model: :default, latency_ms: 0}}
  end

  # Seed stub on peer_b for turn 1; seed recovery response on both survivors
  :rpc.call(peer_b_node, StubServer, :push_response, [
    Shem.LLM.StubTransport.Server,
    resp.("Checkpoint written.")
  ])

  recovery_resp = resp.("Recovered from checkpoint. Completing task.")
  StubServer.set_default(Shem.LLM.StubTransport.Server, recovery_resp)

  :rpc.call(peer_c_node, StubServer, :set_default, [
    Shem.LLM.StubTransport.Server,
    recovery_resp
  ])

  step("Spawning worker_alpha on #{peer_b_node} (max_turns: 2)...")

  {:ok, alpha_name, alpha_sid} =
    Agent.start(%Config{
      task: "Analyze distributed task boundaries",
      system_prompt: "You are a distributed analysis agent. Complete each turn and report.",
      max_turns: 2,
      conversational: true,
      placement: {:node, peer_b_node}
    })

  # Wait until turn 1 checkpoint is in Mnesia
  unless assert_eventually(
           fn ->
             case Shem.EventLog.MnesiaStore.read_all(alpha_sid) do
               {:ok, events} -> Enum.any?(events, &(&1.type == :agent_checkpoint))
               _ -> false
             end
           end,
           8_000
         ) do
    fail!(2, :checkpoint_timeout, "worker_alpha checkpoint not seen within 8s")
  end

  Process.sleep(500)

  step("Killing #{peer_b_node} mid-task...")
  try do
    :peer.stop(peer_b)
  catch
    :exit, _ -> :ok
  end

  t0 = System.monotonic_time(:millisecond)
  step("Waiting for worker_alpha to relocate...")

  unless assert_eventually(
           fn ->
             case Shem.ProcessRegistry.lookup(alpha_name) do
               {pid, _} -> node(pid) != peer_b_node
               nil -> false
             end
           end,
           15_000
         ) do
    fail!(2, :relocation_timeout, "Horde did not relocate worker_alpha within 15s")
  end

  elapsed = System.monotonic_time(:millisecond) - t0

  case Shem.ProcessRegistry.lookup(alpha_name) do
    {pid, _} -> ok("Relocated to #{node(pid)} in #{elapsed}ms")
    nil -> fail!(2, :not_found, "worker_alpha not found after relocation")
  end

  case Agent.await(alpha_name, 10_000) do
    {:ok, :done} ->
      info("worker_alpha resumed: \"Recovered from checkpoint. Completing task.\"")
      ok("Work continued without interruption.")

    err ->
      fail!(2, err, "worker_alpha did not complete after recovery")
  end

  Map.put(state, :recovery_session_id, alpha_sid)
end
```

- [ ] **Step 3: Verify compilation**

```bash
mix compile 2>&1 | grep -E "^.*error" | head -10
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add lib/mix/tasks/demo.ex
git commit -m "feat: demo task Phase 1 (distributed mesh) and Phase 2 (node recovery)"
```

---

### Task 7: Demo task — Phase 3 (Time-Travel) and Phase 4 (Hardening) + integration run

**Files:**
- Modify: `lib/mix/tasks/demo.ex`

- [ ] **Step 1: Implement `phase_3/1`**

Replace the stub `defp phase_3(state), do: state` with:

```elixir
defp phase_3(%{recovery_session_id: sid} = state) do
  phase_banner("PHASE 3: TIME-TRAVEL (SCRUB + FORK)")

  {:ok, events_before} = EventLog.events(sid)
  step("EventLog for worker_alpha: #{length(events_before)} events")

  # Find the last checkpoint event as the scrub pivot
  pivot =
    events_before
    |> Enum.reverse()
    |> Enum.find(&(&1.type == :agent_checkpoint))

  unless pivot do
    fail!(3, :no_checkpoint, "No agent_checkpoint event found in session #{sid}")
  end

  info("Last checkpoint event: #{pivot.id}")

  :ok = EventLog.scrub(sid, pivot.id)
  {:ok, events_after} = EventLog.events(sid)
  ok("Scrubbed dirty tail — #{length(events_before)} → #{length(events_after)} events")

  # Fork timeline from turn 1 LLM call
  step("Forking timeline from turn 1 checkpoint...")

  alt = [
    %{content: "Taking the alternate path — diverging from original timeline.", tokens_used: 5}
  ]

  case Shem.LLM.Branch.branch_after_call(sid, 0, alt, fn fork_sid -> fork_sid end) do
    {:ok, fork_sid, _} ->
      ok("Fork created.")
      info("Original session: #{sid}")
      info("Fork session:     #{fork_sid}")
      info("Two parallel histories now exist.")

    err ->
      fail!(3, err, "branch_after_call failed")
  end

  state
end
```

- [ ] **Step 2: Define the DemoTool module inside the demo task file**

Add this private module definition near the bottom of `lib/mix/tasks/demo.ex`, before the final `end` of the `Mix.Tasks.Demo` module:

```elixir
  # ── Demo Tool ────────────────────────────────────────────────────────────────

  defp buggy_tool do
    %Shem.Tool{
      id: "demo_word_count",
      name: "word_count",
      module: Shem.Lab.Tool.DemoWordCount,
      source: """
      def run(%{"text" => text}) do
        words = String.split(text)
        {:ok, "\#{length(words)} words"}
      end
      """,
      test_source: "",
      input_schema: %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      },
      graduated_at: DateTime.utc_now()
    }
  end

  defp fixed_tool do
    %Shem.Tool{
      id: "demo_word_count",
      name: "word_count",
      module: Shem.Lab.Tool.DemoWordCount,
      source: """
      def run(%{"text" => nil}), do: {:ok, "0 words"}
      def run(%{"text" => text}), do: {:ok, "\#{length(String.split(text))} words"}
      """,
      test_source: "",
      input_schema: %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      },
      graduated_at: DateTime.utc_now()
    }
  end
```

- [ ] **Step 3: Implement `phase_4/1`**

Replace the stub `defp phase_4(state), do: state` with:

```elixir
defp phase_4(state) do
  phase_banner("PHASE 4: ADVERSARIAL HARDENING")

  tool = buggy_tool()
  step("Graduating demo tool: #{tool.name} (known bug: crashes on nil input)...")
  :ok = Shem.Lab.Registry.register(tool)
  :ok = Shem.Lab.Workspace.graduate(tool)
  ok("word_count registered")

  # Pin all hardening agents to local node so the local stub serves them
  Application.put_env(:shem, :adversarial_agent_placement, {:node, node()})

  resp = fn content ->
    {:ok,
     %Shem.LLM.Response{content: content, tokens_used: 1, model: :default, latency_ms: 0}}
  end

  StubServer.push_response(
    Shem.LLM.StubTransport.Server,
    resp.("FAILURES_FOUND: crashes on nil input")
  )

  StubServer.push_response(
    Shem.LLM.StubTransport.Server,
    resp.("Task complete.")
  )

  StubServer.push_response(
    Shem.LLM.StubTransport.Server,
    resp.("NO_FAILURES_FOUND")
  )

  StubServer.set_default(Shem.LLM.StubTransport.Server, resp.("Task complete."))

  step("Starting HardeningJob...")

  {:ok, job_name} =
    case Shem.Adversarial.start_hardening("demo_word_count") do
      {:ok, :disabled} ->
        fail!(4, :adversarial_disabled, "Shem.Adversarial.Supervisor not running")

      result ->
        result
    end

  job_pid = GenServer.whereis(Shem.ProcessRegistry.via_tuple(job_name))

  # Poll for hardening job phases and narrate as they complete
  poll_hardening(job_pid, state)
end

defp poll_hardening(job_pid, state) do
  # We watch status transitions and narrate each phase
  wait_for_round(job_pid, 1)
  info("[stub] FAILURES_FOUND: crashes on nil input")
  info("[demo] Patching word_count — registering fixed version...")
  fixed = fixed_tool()
  :ok = Shem.Lab.Registry.register(fixed)
  :ok = Shem.Lab.Workspace.graduate(fixed)
  info("[demo] Fixed version graduated")

  wait_for_round(job_pid, 2)
  info("[stub] NO_FAILURES_FOUND")

  # Wait for job to reach :done
  unless assert_eventually(
           fn ->
             case GenServer.call(job_pid, :status) do
               %{status: :done} -> true
               _ -> false
             end
           end,
           30_000
         ) do
    fail!(4, :hardening_timeout, "HardeningJob did not complete within 30s")
  end

  case Shem.Trust.Store.entry("demo_word_count") do
    {:ok, entry} ->
      ok("HardeningJob: real rounds, real EventLog, real trust store. LLM responses scripted.")
      info("Trust score: #{Float.round(entry.score, 2)} | rounds: #{entry.hardening_count}")

    {:error, :unrated} ->
      info("Trust store: no entry (hardening may have errored)")
  end

  state
end

defp wait_for_round(job_pid, target_round) do
  assert_eventually(
    fn ->
      case GenServer.call(job_pid, :status) do
        %{round: r} when r >= target_round -> true
        %{status: :done} -> true
        _ -> false
      end
    end,
    15_000
  )
end
```

- [ ] **Step 4: Compile to verify no errors**

```bash
mix compile 2>&1 | grep -E "error" | head -10
```

Expected: no compilation errors.

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/demo.ex
git commit -m "feat: demo task Phase 3 (scrub+fork) and Phase 4 (adversarial hardening)"
```

- [ ] **Step 6: Run the full demo end-to-end**

```bash
elixir --sname shem_demo -S mix demo
```

Expected output (approximately):

```
═══════════════════════════════════════════════════════════════
  SHEM LAUNCH DEMO
═══════════════════════════════════════════════════════════════

▶ PHASE 1: DISTRIBUTED MESH
  Starting peer node shem_b@localhost...
  ✓  shem_b started
  Starting peer node shem_c@localhost...
  ✓  shem_c started
  Wiring Horde membership across 3 nodes...
  ✓  Horde mesh: 3 nodes
  Spawning worker_alpha → shem_b@localhost
  Spawning worker_beta → shem_c@localhost
    worker_alpha: "Checkpoint written."
    worker_beta: "Parallel analysis running on shem_c…"
  ✓  Two agents ran concurrently across three BEAM nodes.

▶ PHASE 2: NODE FAILURE + RECOVERY
  Spawning worker_alpha on shem_b@localhost (max_turns: 2)...
  Killing shem_b@localhost mid-task...
  Waiting for worker_alpha to relocate...
  ✓  Relocated to shem_demo@localhost in NNNms
    worker_alpha resumed: "Recovered from checkpoint. Completing task."
  ✓  Work continued without interruption.

▶ PHASE 3: TIME-TRAVEL (SCRUB + FORK)
  EventLog for worker_alpha: N events
    Last checkpoint event: evt_...
  ✓  Scrubbed dirty tail — N → M events
  Forking timeline from turn 1 checkpoint...
  ✓  Fork created.
    Original session: ses_...
    Fork session:     ses_...
    Two parallel histories now exist.

▶ PHASE 4: ADVERSARIAL HARDENING
  Graduating demo tool: word_count (known bug: crashes on nil input)...
  ✓  word_count registered
  Starting HardeningJob...
    [stub] FAILURES_FOUND: crashes on nil input
    [demo] Patching word_count — registering fixed version...
    [demo] Fixed version graduated
    [stub] NO_FAILURES_FOUND
  ✓  HardeningJob: real rounds, real EventLog, real trust store. LLM responses scripted.
    Trust score: 1.0 | rounds: 1

═══════════════════════════════════════════════════════════════
  SHEM LAUNCH DEMO COMPLETE
  Distributed mesh ✓  Node recovery ✓  Time-travel ✓  Self-healing ✓
═══════════════════════════════════════════════════════════════
```

If any phase fails, read the `✗ PHASE N FAILED` message and hint for the fix.

- [ ] **Step 7: Run the full test suite to confirm no regressions**

```bash
mix test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 8: Final commit**

```bash
git add lib/mix/tasks/demo.ex
git commit -m "feat: complete mix demo — 4-phase launch demo end-to-end"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| `EventLog.scrub/2` — Store callback | Task 1 |
| `EventLog.scrub/2` — FakeStore | Task 1 |
| `EventLog.scrub/2` — DETSStore | Task 2 |
| `EventLog.scrub/2` — MnesiaStore | Task 3 |
| `EventLog.scrub/2` — public API + GenServer | Task 1 |
| `EventLog.scrub/2` — unit tests | Task 1 |
| `HardeningJob` reads `adversarial_agent_placement` env | Task 4 |
| Demo skeleton, ANSI helpers, `start_peer/1`, `assert_eventually/3` | Task 5 |
| Phase 1 — real peer nodes, Horde mesh, two agents | Task 6 |
| Phase 2 — `:peer.stop`, relocation, checkpoint recovery | Task 6 |
| Per-node stub servers (not global queue) | Task 6 |
| MnesiaStore forced at startup | Task 5 |
| Stub pipeline override before `app.start` | Task 5 |
| Phase 3 — scrub + fork | Task 7 |
| Phase 4 — pin agents locally, HardeningJob, trust store | Task 7 |
| Phase 4 narration uses `[stub]` / `[demo]` labels | Task 7 |
| `Node.alive?()` guard at startup | Task 5 |
| Error handling with hints per phase | Tasks 6–7 |

**Placeholder scan:** No TBDs, TODOs, or vague steps found. All code blocks are complete.

**Type consistency check:**
- `StubServer.push_response/2` second arg is `{:ok, %Shem.LLM.Response{}}` throughout (Tasks 6, 7)
- `Agent.start/1` returns `{:ok, name, session_id}` — matched in Tasks 6, 7
- `Agent.await/2` returns `{:ok, :done | :error | :waiting}` — matched in Tasks 6, 7
- `EventLog.scrub/2` callback signature `(handle, after_event_id)` consistent across Store/FakeStore/DETSStore; MnesiaStore uses `(session_id, after_event_id)` which is correct since handle = session_id for Mnesia
- `Shem.Tool` struct — all required fields (`:id, :name, :module, :source, :test_source, :graduated_at`) present in `buggy_tool/0` and `fixed_tool/0` in Task 7
- `Trust.Store.entry/1` returns `{:ok, %{score: float(), hardening_count: integer(), ...}}` — matched in Task 7
