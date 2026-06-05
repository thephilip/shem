# Phase 10a: Adversarial Self-Improvement Loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically harden graduated tools by running a red team agent against them; when failures are found a target agent patches the tool; the loop repeats until the tool passes or a configurable ceiling is reached.

**Architecture:** `HardeningJob` (GenServer, `:temporary`) orchestrates one hardening run per tool. It starts `Agent.Server` instances for the red team and target agents sequentially, reads results from the EventLog, and terminates on clean pass or max rounds. `Adversarial.Supervisor` (DynamicSupervisor) manages jobs. `GraduationGate` triggers a job automatically after every successful graduation. `/redteam <tool>` in the TUI triggers one manually.

**Tech Stack:** Elixir/OTP, ExUnit, existing `Shem.Agent`, `Shem.EventLog`, `Shem.Lab.Registry`, `Shem.LLM.StubTransport`

---

## File Map

**Create:**
- `lib/shem/adversarial.ex` — public API: `start_hardening/1`, `status/1`
- `lib/shem/adversarial/supervisor.ex` — DynamicSupervisor
- `lib/shem/adversarial/hardening_job.ex` — GenServer orchestrator
- `test/shem/adversarial/hardening_job_test.exs`
- `test/shem/adversarial_test.exs`

**Modify:**
- `lib/shem/agent/turn.ex` — add `strip_thinking/1`, call before `parse_response/1`
- `lib/shem/agent/server.ex` — log final answer in `:agent_done` event; add `:get_answer` handle_call
- `lib/shem/agent.ex` — add `session_id/1` public API
- `lib/shem/lab/registry.ex` — add `lookup_by_name/1`
- `lib/shem/lab/graduation_gate.ex` — fire `Adversarial.start_hardening/1` on success
- `lib/shem/tui/command_dispatch.ex` — add `/redteam` clause
- `lib/shem/tui/app.ex` — route `{:redteam, name}` dispatch
- `lib/shem/application.ex` — add `Adversarial.Supervisor` child + guard function
- `config/dev.exs` — add `adversarial_max_rounds`, `adversarial_agent_timeout_ms`
- `config/test.exs` — add `start_adversarial: false`
- `test/shem/agent/turn_test.exs` — thinking-token tests
- `test/shem/lab/registry_test.exs` — `lookup_by_name` tests
- `test/shem/tui/command_dispatch_test.exs` — `/redteam` test

---

### Task 1: Thinking token stripping in `Turn`

**Files:**
- Modify: `lib/shem/agent/turn.ex`
- Modify: `test/shem/agent/turn_test.exs`

- [ ] **Step 1: Write failing tests**

Add inside the existing `describe "parse_response/1"` block in `test/shem/agent/turn_test.exs`:

```elixir
describe "strip_thinking/1 (via step/4 behaviour)" do
  test "parse_response strips <think> block before extracting tool calls" do
    content = "<think>\nLet me think. {\"tool\": \"fake\", \"args\": {}}\n</think>\n{\"tool\": \"list_tools\", \"args\": {}}"
    assert {:tool_calls, [%{tool: "list_tools"}], _} = Turn.parse_response(Turn.strip_thinking(content))
  end

  test "parse_response on content without <think> block is unchanged" do
    content = "{\"tool\": \"list_tools\", \"args\": {}}"
    assert Turn.strip_thinking(content) == content
  end

  test "strip_thinking removes multiline think block" do
    content = "<think>\nsome\nmultiline\nthinking\n</think>\nhello"
    assert Turn.strip_thinking(content) == "hello"
  end
end
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /home/philip/Downloads/_project/shem
mix test test/shem/agent/turn_test.exs --seed 0 2>&1 | tail -10
```

Expected: 3 failures — `Turn.strip_thinking/1` is undefined.

- [ ] **Step 3: Add `strip_thinking/1` and wire it into `step/4`**

In `lib/shem/agent/turn.ex`, add the private function after `parse_response/1`:

```elixir
@doc false
def strip_thinking(content) do
  Regex.replace(~r/<think>.*?<\/think>/s, content, "") |> String.trim()
end
```

Then update `step/4` — replace the line:

```elixir
      {:ok, %Response{content: content}} -> parse_response(content)
```

with:

```elixir
      {:ok, %Response{content: content}} -> content |> strip_thinking() |> parse_response()
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/agent/turn_test.exs --seed 0 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 5: Run full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all 379 tests pass (+ 3 new = 382).

- [ ] **Step 6: Commit**

```bash
git add lib/shem/agent/turn.ex test/shem/agent/turn_test.exs
git commit -m "feat: strip <think> tokens from LLM response before tool call parsing"
```

---

### Task 2: `Lab.Registry.lookup_by_name/1`

**Files:**
- Modify: `lib/shem/lab/registry.ex`
- Modify: `test/shem/lab/registry_test.exs`

- [ ] **Step 1: Write failing tests**

Add a new describe block at the end of `test/shem/lab/registry_test.exs`:

```elixir
describe "lookup_by_name/1" do
  test "returns {:ok, tool} when a tool with that name exists" do
    source = """
    defmodule LookupByNameTool do
      def run(_args), do: :ok
    end
    """
    test_src = """
    defmodule LookupByNameToolTest do
      def run, do: :ok
    end
    """
    {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
    assert {:ok, found} = Shem.Lab.Registry.lookup_by_name(tool.name)
    assert found.id == tool.id
  end

  test "returns {:error, :not_found} for unknown name" do
    assert {:error, :not_found} = Shem.Lab.Registry.lookup_by_name("no_such_tool")
  end
end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/lab/registry_test.exs --seed 0 2>&1 | tail -10
```

Expected: 2 failures — `lookup_by_name/1` undefined.

- [ ] **Step 3: Add `lookup_by_name/1` to `Lab.Registry`**

In `lib/shem/lab/registry.ex`, add to the client API section (after `lookup/1`):

```elixir
@spec lookup_by_name(String.t()) :: {:ok, Tool.t()} | {:error, :not_found}
def lookup_by_name(name), do: GenServer.call(__MODULE__, {:lookup_by_name, name})
```

Add to the server callbacks section (after `handle_call({:lookup, id}, ...)`):

```elixir
@impl true
def handle_call({:lookup_by_name, name}, _from, state) do
  result =
    state.table
    |> :ets.tab2list()
    |> Enum.find(fn {_id, tool} -> tool.name == name end)
    |> case do
      {_id, tool} -> {:ok, tool}
      nil -> {:error, :not_found}
    end

  {:reply, result, state}
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/lab/registry_test.exs --seed 0 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 5: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/lab/registry.ex test/shem/lab/registry_test.exs
git commit -m "feat: add Lab.Registry.lookup_by_name/1"
```

---

### Task 3: `Agent.session_id/1` + answer in `:agent_done` event

HardeningJob needs to read the red team agent's final answer from the EventLog after awaiting it. This task logs that answer into the `:agent_done` event and exposes the session_id via public API.

**Files:**
- Modify: `lib/shem/agent/server.ex`
- Modify: `lib/shem/agent.ex`
- Modify: `test/shem/agent/server_test.exs`

- [ ] **Step 1: Write a failing test**

Add to `test/shem/agent/server_test.exs` inside `describe "single-turn run (no tool calls)"`:

```elixir
test ":agent_done event contains content when agent finishes with plain text" do
  stub("The final answer.")
  name = start_agent("what is the answer?")
  Agent.await(name, 2_000)

  {:ok, session_id} = Agent.session_id(name)
  {:ok, events} = Shem.EventLog.events(session_id)
  done_event = Enum.find(events, &(&1.type == :agent_done))
  assert done_event != nil
  assert Map.get(done_event.data, :content) == "The final answer."
end

test "Agent.session_id/1 returns {:ok, binary} for a running agent" do
  stub("done")
  name = start_agent("task")
  assert {:ok, sid} = Agent.session_id(name)
  assert is_binary(sid)
end

test "Agent.session_id/1 returns {:error, :not_found} for unknown agent" do
  assert {:error, :not_found} = Agent.session_id("no_such_agent_xyz")
end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/agent/server_test.exs --seed 0 2>&1 | tail -10
```

Expected: 3 failures — `Agent.session_id/1` undefined.

- [ ] **Step 3: Update `Agent.Server.finish/2` to log final answer**

In `lib/shem/agent/server.ex`, replace the existing `finish/3`:

```elixir
defp finish(state, status, :answer) do
  last_content =
    state.history
    |> Enum.filter(&(&1.role == :assistant))
    |> List.last()
    |> Map.get(:content, "")

  EventLog.append(state.session_id, :agent_done, %{reason: :answer, content: last_content})
  Enum.each(state.awaiting, fn from -> GenServer.reply(from, {:ok, status}) end)
  %{state | status: status, done_reason: :answer, awaiting: []}
end

defp finish(state, status, reason) do
  EventLog.append(state.session_id, :agent_done, %{reason: reason})
  Enum.each(state.awaiting, fn from -> GenServer.reply(from, {:ok, status}) end)
  %{state | status: status, done_reason: reason, awaiting: []}
end
```

- [ ] **Step 4: Add `session_id/1` to `Shem.Agent`**

In `lib/shem/agent.ex`, add after `await/2`:

```elixir
@spec session_id(String.t()) :: {:ok, String.t()} | {:error, :not_found}
def session_id(name) do
  case GenServer.whereis(ProcessRegistry.via_tuple(name)) do
    nil -> {:error, :not_found}
    pid -> {:ok, GenServer.call(pid, :session_id)}
  end
end
```

- [ ] **Step 5: Run tests**

```bash
mix test test/shem/agent/server_test.exs --seed 0 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 6: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/agent/server.ex lib/shem/agent.ex test/shem/agent/server_test.exs
git commit -m "feat: log final answer in :agent_done event; add Agent.session_id/1"
```

---

### Task 4: Config additions

**Files:**
- Modify: `config/dev.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Add adversarial config to `dev.exs`**

Add at the end of `config/dev.exs`:

```elixir
config :shem,
  adversarial_max_rounds: 5,
  adversarial_agent_timeout_ms: 300_000
```

- [ ] **Step 2: Add guard to `test.exs`**

Add at the end of `config/test.exs`:

```elixir
config :shem, start_adversarial: false
config :shem, adversarial_max_rounds: 3
config :shem, adversarial_agent_timeout_ms: 5_000
```

- [ ] **Step 3: Verify compile**

```bash
mix compile 2>&1 | tail -5
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add config/dev.exs config/test.exs
git commit -m "config: add adversarial loop settings"
```

---

### Task 5: `CommandDispatch` — `/redteam` command

**Files:**
- Modify: `lib/shem/tui/command_dispatch.ex`
- Modify: `test/shem/tui/command_dispatch_test.exs`

- [ ] **Step 1: Write failing test**

Add to `test/shem/tui/command_dispatch_test.exs`:

```elixir
describe "/redteam command" do
  test "parses /redteam <name> into {:redteam, name}" do
    assert {:redteam, "my_tool"} = CommandDispatch.parse("/redteam my_tool")
  end

  test "trims whitespace from tool name" do
    assert {:redteam, "my_tool"} = CommandDispatch.parse("/redteam  my_tool  ")
  end

  test "returns error for /redteam with no tool name" do
    assert {:error, _} = CommandDispatch.parse("/redteam")
    assert {:error, _} = CommandDispatch.parse("/redteam   ")
  end
end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/tui/command_dispatch_test.exs --seed 0 2>&1 | tail -10
```

Expected: 3 failures.

- [ ] **Step 3: Add clause to `CommandDispatch.parse/1`**

Read `lib/shem/tui/command_dispatch.ex` and add before the catch-all clause:

```elixir
def parse("/redteam" <> rest) do
  name = String.trim(rest)
  if name == "" do
    {:error, "usage: /redteam <tool_name>"}
  else
    {:redteam, name}
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/tui/command_dispatch_test.exs --seed 0 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 5: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/command_dispatch.ex test/shem/tui/command_dispatch_test.exs
git commit -m "feat: add /redteam <tool_name> command to CommandDispatch"
```

---

### Task 6: `Adversarial.Supervisor` + Application wiring

**Files:**
- Create: `lib/shem/adversarial/supervisor.ex`
- Modify: `lib/shem/application.ex`

- [ ] **Step 1: Create `Adversarial.Supervisor`**

Create `lib/shem/adversarial/supervisor.ex`:

```elixir
defmodule Shem.Adversarial.Supervisor do
  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
```

- [ ] **Step 2: Add guard function and child to `Application`**

In `lib/shem/application.ex`, add `adversarial_children/0` alongside the other guard functions:

```elixir
defp adversarial_children do
  if Application.get_env(:shem, :start_adversarial, true) do
    [Shem.Adversarial.Supervisor]
  else
    []
  end
end
```

And add `adversarial_children()` to the children list in `start/2`, before `llm_stub_children()`:

```elixir
children =
  [
    {Horde.Registry, [name: Shem.Registry, keys: :unique, members: :auto]},
    Shem.AgentSupervisor,
    Shem.EventLog,
    {Task.Supervisor, name: Shem.Lab.TaskSupervisor},
    Shem.Lab.Registry,
    Shem.LLM.BudgetServer
  ] ++
    adversarial_children() ++
    llm_stub_children() ++
    mcp_children() ++
    cluster_children() ++
    tui_children()
```

- [ ] **Step 3: Verify the app starts**

```bash
mix compile 2>&1 | tail -5
```

Expected: compiles clean.

- [ ] **Step 4: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass (supervisor not started in test env).

- [ ] **Step 5: Commit**

```bash
git add lib/shem/adversarial/supervisor.ex lib/shem/application.ex
git commit -m "feat: add Adversarial.Supervisor DynamicSupervisor and Application wiring"
```

---

### Task 7: `HardeningJob` GenServer

**Files:**
- Create: `lib/shem/adversarial/hardening_job.ex`
- Create: `test/shem/adversarial/hardening_job_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/shem/adversarial/hardening_job_test.exs`:

```elixir
defmodule Shem.Adversarial.HardeningJobTest do
  use ExUnit.Case, async: false

  alias Shem.Adversarial.HardeningJob
  alias Shem.{Agent, EventLog, Lab}
  alias Shem.LLM.{Response, StubTransport}

  @tool_source """
  defmodule HardeningJobTestTool do
    def run(_args), do: :ok
  end
  """
  @tool_test_src """
  defmodule HardeningJobTestToolTest do
    def run, do: :ok
  end
  """

  setup do
    StubTransport.Server.reset()
    Shem.LLM.BudgetServer.reset()
    lab_dir = Application.get_env(:shem, :lab_dir)
    on_exit(fn ->
      File.rm_rf!(lab_dir)
      Lab.Registry.flush()
    end)

    # Disable auto-hardening during setup graduation
    Application.put_env(:shem, :start_adversarial, false)
    {:ok, tool} = Lab.GraduationGate.run(@tool_source, @tool_test_src)
    Application.put_env(:shem, :start_adversarial, true)

    {:ok, tool: tool}
  end

  defp stub(content, tokens \\ 5) do
    StubTransport.Server.push_response(
      {:ok, %Response{content: content, tokens_used: tokens, model: :default, latency_ms: 1}}
    )
  end

  defp wait_done(pid, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(pid, deadline)
  end

  defp do_wait(pid, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case GenServer.call(pid, :status) do
        %{status: :done} -> :ok
        _ ->
          Process.sleep(20)
          do_wait(pid, deadline)
      end
    end
  end

  defp hardening_events(session_id) do
    {:ok, events} = EventLog.events(session_id)
    events
  end

  describe "clean pass on round 1" do
    test "logs :hardening_started, :hardening_round_started, :hardening_attack_complete, :hardening_completed with outcome :clean", %{tool: tool} do
      stub("NO_FAILURES_FOUND")

      {:ok, pid} = HardeningJob.start_link({tool.id, []})
      {:ok, session_id} = GenServer.call(pid, :session_id)
      :ok = wait_done(pid)

      events = hardening_events(session_id)
      types = Enum.map(events, & &1.type)
      assert :hardening_started in types
      assert :hardening_round_started in types
      assert :hardening_attack_complete in types
      assert :hardening_completed in types

      done = Enum.find(events, &(&1.type == :hardening_completed))
      assert done.data.outcome == :clean
      assert done.data.rounds == 0
    end
  end

  describe "failure round 1, clean round 2" do
    test "runs 2 rounds and completes with :clean", %{tool: tool} do
      stub("FAILURES_FOUND: off-by-one on negative inputs")
      stub("I have fixed the tool.")
      stub("NO_FAILURES_FOUND")

      {:ok, pid} = HardeningJob.start_link({tool.id, []})
      {:ok, session_id} = GenServer.call(pid, :session_id)
      :ok = wait_done(pid)

      events = hardening_events(session_id)
      done = Enum.find(events, &(&1.type == :hardening_completed))
      assert done.data.outcome == :clean
      assert done.data.rounds == 1

      patch = Enum.find(events, &(&1.type == :hardening_patch_complete))
      assert patch != nil
    end
  end

  describe "max rounds reached" do
    test "stops after max_rounds with outcome :max_rounds_reached", %{tool: tool} do
      # max_rounds is 3 in test config; need 3 failure+patch cycles
      stub("FAILURES_FOUND: error 1")
      stub("Fixed 1.")
      stub("FAILURES_FOUND: error 2")
      stub("Fixed 2.")
      stub("FAILURES_FOUND: error 3")
      stub("Fixed 3.")

      {:ok, pid} = HardeningJob.start_link({tool.id, []}  )
      {:ok, session_id} = GenServer.call(pid, :session_id)
      :ok = wait_done(pid, 10_000)

      events = hardening_events(session_id)
      done = Enum.find(events, &(&1.type == :hardening_completed))
      assert done.data.outcome == :max_rounds_reached
      assert done.data.rounds == 3
    end
  end

  describe "ambiguous red team response" do
    test "treats anything other than FAILURES_FOUND as clean", %{tool: tool} do
      stub("I am not sure what happened here.")

      {:ok, pid} = HardeningJob.start_link({tool.id, []})
      {:ok, session_id} = GenServer.call(pid, :session_id)
      :ok = wait_done(pid)

      events = hardening_events(session_id)
      done = Enum.find(events, &(&1.type == :hardening_completed))
      assert done.data.outcome == :clean
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/adversarial/hardening_job_test.exs --seed 0 2>&1 | tail -10
```

Expected: failures — `HardeningJob` undefined.

- [ ] **Step 3: Create `HardeningJob`**

Create `lib/shem/adversarial/hardening_job.ex`:

```elixir
defmodule Shem.Adversarial.HardeningJob do
  use GenServer

  alias Shem.{Agent, EventLog, Lab}
  alias Shem.Agent.Config

  def start_link({tool_id, opts}) do
    GenServer.start_link(__MODULE__, tool_id, opts)
  end

  # ── Client API ─────────────────────────────────────────────────────────────

  def await(pid, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(pid, deadline)
  end

  defp do_await(pid, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case GenServer.call(pid, :status) do
        %{status: :done} -> :ok
        _ ->
          Process.sleep(20)
          do_await(pid, deadline)
      end
    end
  end

  # ── Init ───────────────────────────────────────────────────────────────────

  @impl true
  def init(tool_id) do
    max_rounds = Application.get_env(:shem, :adversarial_max_rounds, 5)

    case Lab.Registry.lookup(tool_id) do
      {:ok, tool} ->
        {:ok, session_id} = EventLog.start_session()
        EventLog.append(session_id, :hardening_started, %{
          tool: tool.name,
          tool_id: tool_id,
          max_rounds: max_rounds
        })

        state = %{
          tool_id: tool_id,
          tool_name: tool.name,
          round: 0,
          max_rounds: max_rounds,
          session_id: session_id,
          status: :running
        }

        send(self(), :run_round)
        {:ok, state}

      {:error, :not_found} ->
        {:stop, :tool_not_found}
    end
  end

  # ── Callbacks ──────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{tool: state.tool_name, round: state.round, status: state.status}, state}
  end

  def handle_call(:session_id, _from, state) do
    {:reply, {:ok, state.session_id}, state}
  end

  @impl true
  def handle_info(:run_round, %{status: :running} = state) do
    EventLog.append(state.session_id, :hardening_round_started, %{
      round: state.round + 1,
      tool: state.tool_name
    })

    case Lab.Registry.lookup(state.tool_id) do
      {:ok, tool} ->
        run_red_team(state, tool)

      {:error, :not_found} ->
        {:noreply, finish(state, :error)}
    end
  end

  def handle_info(:run_round, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Loop helpers ───────────────────────────────────────────────────────────

  defp run_red_team(state, tool) do
    timeout = Application.get_env(:shem, :adversarial_agent_timeout_ms, 300_000)

    case Agent.start(red_team_config(tool)) do
      {:ok, agent_name} ->
        Agent.await(agent_name, timeout)
        answer = get_red_team_answer(agent_name)
        result = parse_red_team_result(answer)

        EventLog.append(state.session_id, :hardening_attack_complete, %{
          round: state.round + 1,
          failures_found: result != :clean,
          summary: if(result == :clean, do: nil, else: elem(result, 1))
        })

        case result do
          :clean ->
            {:noreply, finish(state, :clean)}

          {:failures, summary} ->
            run_target(state, tool, summary)
        end

      {:error, _reason} ->
        {:noreply, finish(state, :error)}
    end
  end

  defp run_target(state, tool, summary) do
    timeout = Application.get_env(:shem, :adversarial_agent_timeout_ms, 300_000)

    case Agent.start(target_config(tool, summary)) do
      {:ok, agent_name} ->
        Agent.await(agent_name, timeout)
        new_round = state.round + 1

        EventLog.append(state.session_id, :hardening_patch_complete, %{
          round: new_round,
          tool: state.tool_name
        })

        new_state = %{state | round: new_round}

        if new_state.round >= new_state.max_rounds do
          {:noreply, finish(new_state, :max_rounds_reached)}
        else
          send(self(), :run_round)
          {:noreply, new_state}
        end

      {:error, _reason} ->
        {:noreply, finish(state, :error)}
    end
  end

  defp finish(state, outcome) do
    EventLog.append(state.session_id, :hardening_completed, %{
      tool: state.tool_name,
      rounds: state.round,
      outcome: outcome
    })

    %{state | status: :done}
  end

  # ── Agent configs ──────────────────────────────────────────────────────────

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
      max_turns: 10
    }
  end

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
      max_turns: 10
    }
  end

  # ── Result parsing ─────────────────────────────────────────────────────────

  defp parse_red_team_result(answer) do
    cond do
      String.contains?(answer, "FAILURES_FOUND:") ->
        summary = answer |> String.split("FAILURES_FOUND:") |> List.last() |> String.trim()
        {:failures, summary}

      String.contains?(answer, "NO_FAILURES_FOUND") ->
        :clean

      true ->
        # ambiguous — treat as clean to prevent infinite loops
        :clean
    end
  end

  defp get_red_team_answer(agent_name) do
    case Agent.session_id(agent_name) do
      {:ok, session_id} ->
        {:ok, events} = EventLog.events(session_id)

        events
        |> Enum.filter(&(&1.type == :agent_done))
        |> List.last()
        |> case do
          %{data: %{content: content}} -> content
          _ -> ""
        end

      {:error, :not_found} ->
        ""
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/adversarial/hardening_job_test.exs --seed 0 2>&1 | tail -10
```

Expected: all 4 tests pass.

- [ ] **Step 5: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/adversarial/hardening_job.ex test/shem/adversarial/hardening_job_test.exs
git commit -m "feat: HardeningJob GenServer — adversarial loop orchestrator"
```

---

### Task 8: `Shem.Adversarial` public API

**Files:**
- Create: `lib/shem/adversarial.ex`
- Create: `test/shem/adversarial_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/shem/adversarial_test.exs`:

```elixir
defmodule Shem.AdversarialTest do
  use ExUnit.Case, async: false

  alias Shem.{Adversarial, Lab}
  alias Shem.LLM.{Response, StubTransport}

  @tool_source """
  defmodule AdversarialApiTestTool do
    def run(_args), do: :ok
  end
  """
  @tool_test_src """
  defmodule AdversarialApiTestToolTest do
    def run, do: :ok
  end
  """

  setup do
    StubTransport.Server.reset()
    Shem.LLM.BudgetServer.reset()
    lab_dir = Application.get_env(:shem, :lab_dir)
    on_exit(fn ->
      File.rm_rf!(lab_dir)
      Lab.Registry.flush()
    end)
    :ok
  end

  describe "start_hardening/1 when supervisor not running" do
    test "returns {:ok, :disabled} without crashing" do
      # In test env, start_adversarial: false so Supervisor isn't started
      assert {:ok, :disabled} = Adversarial.start_hardening("some_id")
    end
  end

  describe "status/1" do
    test "returns {:error, :not_found} for unknown job name" do
      assert {:error, :not_found} = Adversarial.status("no_such_job")
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/adversarial_test.exs --seed 0 2>&1 | tail -10
```

Expected: failures — `Shem.Adversarial` undefined.

- [ ] **Step 3: Create `lib/shem/adversarial.ex`**

```elixir
defmodule Shem.Adversarial do
  alias Shem.Adversarial.{Supervisor, HardeningJob}
  alias Shem.ProcessRegistry

  @spec start_hardening(String.t()) ::
          {:ok, String.t()} | {:ok, :disabled} | {:error, term()}
  def start_hardening(tool_id) do
    case Process.whereis(Supervisor) do
      nil ->
        {:ok, :disabled}

      _pid ->
        job_name = "hardening_" <> Base.encode16(:crypto.strong_rand_bytes(4))
        via = ProcessRegistry.via_tuple(job_name)

        case DynamicSupervisor.start_child(Supervisor, {HardeningJob, {tool_id, [name: via]}}) do
          {:ok, _pid} -> {:ok, job_name}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(job_name) do
    case GenServer.whereis(ProcessRegistry.via_tuple(job_name)) do
      nil -> {:error, :not_found}
      pid -> {:ok, GenServer.call(pid, :status)}
    end
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/adversarial_test.exs --seed 0 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 5: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/adversarial.ex test/shem/adversarial_test.exs
git commit -m "feat: Shem.Adversarial public API — start_hardening/1 and status/1"
```

---

### Task 9: `GraduationGate` hook

**Files:**
- Modify: `lib/shem/lab/graduation_gate.ex`

- [ ] **Step 1: Add the fire-and-forget hook**

In `lib/shem/lab/graduation_gate.ex`, find the `{:ok, tool}` success path (line 35: `:ok = Registry.register(tool)`) and add one line after it:

```elixir
:ok = Registry.register(tool)
Shem.Adversarial.start_hardening(tool.id)
{:ok, tool}
```

The full block becomes:

```elixir
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
          Shem.Adversarial.start_hardening(tool.id)
          {:ok, tool}
        else
          {:error, :compile, reason} -> {:error, :compile, reason}
        end
```

- [ ] **Step 2: Full suite — confirm no regressions**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass. `Adversarial.start_hardening/1` returns `{:ok, :disabled}` in test env (supervisor not running), so existing graduation tests are unaffected.

- [ ] **Step 3: Commit**

```bash
git add lib/shem/lab/graduation_gate.ex
git commit -m "feat: trigger Adversarial.start_hardening after every tool graduation"
```

---

### Task 10: TUI App routing for `/redteam`

**Files:**
- Modify: `lib/shem/tui/app.ex`

- [ ] **Step 1: Add routing clause**

In `lib/shem/tui/app.ex`, find the `{:event, %{key: @enter}}` block and add a clause for `{:redteam, tool_name}` after `{:list_agents}`:

```elixir
          {:redteam, tool_name} ->
            case Shem.Lab.Registry.lookup_by_name(tool_name) do
              {:ok, tool} ->
                Shem.Adversarial.start_hardening(tool.id)
                %{model | command_buffer: "", command_error: nil}

              {:error, :not_found} ->
                %{model | command_error: "unknown tool: #{tool_name}"}
            end
```

The full enter block now reads:

```elixir
      {:event, %{key: @enter}} when model.command_buffer != "" ->
        case CommandDispatch.parse(model.command_buffer) do
          {:start_agent, preset_name, task} ->
            case Shem.Agent.start_with_preset(preset_name, task) do
              {:ok, name} ->
                %{model | command_buffer: "", focused_agent: name, command_error: nil}

              {:error, reason} ->
                %{model | command_error: "failed to start agent: #{inspect(reason)}"}
            end

          {:stop_agent} ->
            if model.focused_agent, do: Shem.Agent.stop(model.focused_agent)
            %{model | command_buffer: "", command_error: nil}

          {:list_agents} ->
            %{model | command_buffer: "", command_error: nil}

          {:redteam, tool_name} ->
            case Shem.Lab.Registry.lookup_by_name(tool_name) do
              {:ok, tool} ->
                Shem.Adversarial.start_hardening(tool.id)
                %{model | command_buffer: "", command_error: nil}

              {:error, :not_found} ->
                %{model | command_error: "unknown tool: #{tool_name}"}
            end

          {:error, reason} ->
            %{model | command_error: reason}
        end
```

- [ ] **Step 2: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add lib/shem/tui/app.ex
git commit -m "feat: route /redteam command in TUI App to Adversarial.start_hardening"
```

---

## Self-Review

**Spec coverage:**
- ✅ Thinking token stripping (Turn.strip_thinking/1) — Task 1
- ✅ Lab.Registry.lookup_by_name/1 — Task 2
- ✅ Agent.session_id/1 + answer in :agent_done — Task 3
- ✅ adversarial_max_rounds, adversarial_agent_timeout_ms config — Task 4
- ✅ /redteam <name> CommandDispatch — Task 5
- ✅ Adversarial.Supervisor (DynamicSupervisor) + Application guard — Task 6
- ✅ HardeningJob GenServer with clean/failure/max_rounds/ambiguous test cases — Task 7
- ✅ Shem.Adversarial public API (start_hardening/1, status/1) — Task 8
- ✅ GraduationGate hook (fire and forget) — Task 9
- ✅ TUI App /redteam routing — Task 10
- ✅ start_adversarial: false guard — Tasks 4 + 6
- ✅ :temporary restart strategy — specified in HardeningJob (uses GenServer defaults; DynamicSupervisor children are :temporary by default)
- ✅ All event types logged — HardeningJob Task 7

**Placeholder scan:** None found. All code blocks are complete.

**Type consistency:**
- `tool_id :: String.t()` used consistently in HardeningJob, Adversarial, GraduationGate hook
- `job_name :: String.t()` returned by `start_hardening/1`, accepted by `status/1`
- `Agent.session_id/1` returns `{:ok, String.t()}` — used as such in `get_red_team_answer/1`
- `parse_red_team_result/1` returns `:clean | {:failures, String.t()}` — matched consistently
