# Phase 13 — Session History Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a TUI history browser (`h` key) that lists all past agent sessions, shows full turn-by-turn detail for the selected session, and lets the user resume any past session with `r`.

**Architecture:** `EventLog.read_session_events/1` handles reading events from any session (active handle or disk DETS file). `HistoryScanner.scan/0` discovers all session files and builds summaries. A new `:history` TUI mode (layout: split list + detail) wires these together via `App` model fields and key bindings. `Agent.resume/2` reuses the existing `Checkpoint.reconstruct` path by starting an agent with a caller-supplied `session_id`.

**Tech Stack:** Elixir/OTP, Ratatouille TUI, DETS (direct access for disk reads), existing `AgentView`/`EventLog`/`Agent` modules.

---

## File Map

| File | Change |
|------|--------|
| `lib/shem/event_log.ex` | Add `read_session_events/1` client + server callback |
| `lib/shem/event_log/history_scanner.ex` | New — discover + summarise past sessions |
| `lib/shem/tui/agent_view.ex` | Extract `from_events/1`; `build/1` becomes thin wrapper |
| `lib/shem/agent_supervisor.ex` | Add `start_agent/3` overload accepting caller-supplied `session_id` |
| `lib/shem/agent.ex` | Add `resume/2` |
| `lib/shem/tui/views/history.ex` | New — split list+detail view |
| `lib/shem/tui/app.ex` | New model fields, history key bindings, render dispatch |
| `test/shem/event_log_test.exs` | `read_session_events/1` tests |
| `test/shem/event_log/history_scanner_test.exs` | New — HistoryScanner tests |
| `test/shem/tui/agent_view_test.exs` | Port existing tests to `from_events/1`; keep `build/1` smoke test |
| `test/shem/agent_test.exs` | `resume/2` tests |
| `test/shem/tui/app_test.exs` | History mode key binding tests |
| `test/shem/tui/views/history_test.exs` | New — render tests |

---

## Task 1: `EventLog.read_session_events/1`

**Files:**
- Modify: `lib/shem/event_log.ex`
- Modify: `test/shem/event_log_test.exs`

### Background

`EventLog.events/1` only reads from sessions with an open handle (active in the current runtime). `read_session_events/1` extends this: if the session has an open handle, use it; otherwise, open the raw DETS file from disk, read all events, and close it. The DETS read bypasses the `Store` behaviour and goes directly to `:dets` — this is intentional since FakeStore (used in tests) has no disk state, and the disk-read path is DETS-specific by nature.

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/event_log_test.exs`, after the existing `describe` blocks:

```elixir
describe "read_session_events/1" do
  test "returns events for an active session" do
    {:ok, sid} = EventLog.start_session()
    {:ok, _} = EventLog.append(sid, :agent_started, %{task: "active task"})
    assert {:ok, events} = EventLog.read_session_events(sid)
    assert length(events) == 1
    assert hd(events).type == :agent_started
  end

  test "returns {:error, :not_found} for an unknown session with no dets file" do
    assert {:error, :not_found} = EventLog.read_session_events("ses_TOTALLY_UNKNOWN_XYZ")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/philip/Downloads/_project/shem
mix test test/shem/event_log_test.exs --only "read_session_events" 2>&1 | tail -20
```

Expected: two failures with `** (UndefinedFunctionError) function Shem.EventLog.read_session_events/1 is undefined`.

- [ ] **Step 3: Add the client API to `lib/shem/event_log.ex`**

After the existing `event/2` spec (around line 39), add:

```elixir
@spec read_session_events(String.t()) :: {:ok, [Event.t()]} | {:error, :not_found}
def read_session_events(session_id),
  do: GenServer.call(__MODULE__, {:read_session_events, session_id})
```

- [ ] **Step 4: Add the server callback to `lib/shem/event_log.ex`**

After the existing `handle_call({:events, ...})` clause (around line 124), add:

```elixir
@impl true
def handle_call({:read_session_events, session_id}, _from, state) do
  case Map.fetch(state.sessions, session_id) do
    {:ok, {handle, _}} when handle != nil ->
      {:reply, state.store.read_all(handle), state}

    _ ->
      path = event_log_path()
      dets_path = Path.join(path, "#{session_id}.dets")

      if File.exists?(dets_path) do
        table = :"shem_history_#{session_id}_#{:erlang.unique_integer([:positive])}"
        file_charlist = String.to_charlist(dets_path)

        case :dets.open_file(table, file: file_charlist, type: :set) do
          {:ok, tab} ->
            events =
              :dets.foldl(fn {_id, event}, acc -> [event | acc] end, [], tab)
              |> Enum.sort_by(& &1.timestamp, DateTime)

            :dets.close(tab)
            {:reply, {:ok, events}, state}

          {:error, _} ->
            {:reply, {:error, :not_found}, state}
        end
      else
        {:reply, {:error, :not_found}, state}
      end
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/shem/event_log_test.exs 2>&1 | tail -10
```

Expected: all event_log tests pass.

- [ ] **Step 6: Run full suite to check for regressions**

```bash
mix test 2>&1 | tail -5
```

Expected: same count as before (482 passing).

- [ ] **Step 7: Commit**

```bash
git add lib/shem/event_log.ex test/shem/event_log_test.exs
git commit -m "feat: EventLog — add read_session_events/1 for active and disk sessions"
```

---

## Task 2: `AgentView.from_events/1` Refactor

**Files:**
- Modify: `lib/shem/tui/agent_view.ex`
- Modify: `test/shem/tui/agent_view_test.exs`

### Background

All fold logic moves into a new pure `from_events/1`. The existing `build/1` becomes a thin wrapper. The history browser will call `from_events/1` directly with events fetched via `read_session_events/1`.

- [ ] **Step 1: Write the new `from_events/1` test**

Add a new `describe "from_events/1"` block in `test/shem/tui/agent_view_test.exs`, just before the closing `end` of the module:

```elixir
describe "from_events/1" do
  alias Shem.EventLog.Event

  defp evt(session_id, type, payload) do
    Event.new(session_id, type, payload)
  end

  test "returns empty struct for empty list" do
    view = AgentView.from_events([])
    assert view.status == :running
    assert view.turn_count == 0
    assert view.history == []
  end

  test "sets max_turns from agent_started payload" do
    events = [evt("s", :agent_started, %{task: "t", model: :default, max_turns: 7})]
    view = AgentView.from_events(events)
    assert view.max_turns == 7
  end

  test "status becomes :done on agent_done event" do
    events = [
      evt("s", :agent_started, %{task: "t", model: :default, max_turns: 20}),
      evt("s", :agent_done, %{reason: :answer})
    ]
    view = AgentView.from_events(events)
    assert view.status == :done
  end

  test "recent_events contains last 10 event types" do
    events =
      for i <- 1..12 do
        evt("s", :agent_turn_started, %{turn: i})
      end
    view = AgentView.from_events(events)
    assert length(view.recent_events) == 10
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
mix test test/shem/tui/agent_view_test.exs --only "from_events" 2>&1 | tail -10
```

Expected: failures with `undefined function AgentView.from_events/1`.

- [ ] **Step 3: Refactor `lib/shem/tui/agent_view.ex`**

Replace the existing `build/1` function with:

```elixir
@spec build(String.t()) :: {:ok, t()} | :not_found
def build(session_id) do
  case Shem.EventLog.events(session_id) do
    {:ok, []} -> :not_found
    {:ok, events} -> {:ok, from_events(events)}
    _ -> :not_found
  end
end

@spec from_events([Shem.EventLog.Event.t()]) :: t()
def from_events([]), do: %__MODULE__{}

def from_events(events) do
  view = Enum.reduce(events, %__MODULE__{}, &fold_event/2)
  recent = events |> Enum.map(& &1.type) |> Enum.take(-10)
  %{view | recent_events: recent}
end
```

The `fold_event/2` private function remains unchanged.

- [ ] **Step 4: Run all agent_view tests**

```bash
mix test test/shem/tui/agent_view_test.exs 2>&1 | tail -10
```

Expected: all pass (existing `build/1` tests still pass, new `from_events/1` tests pass).

- [ ] **Step 5: Run full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all 482 tests still passing.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/agent_view.ex test/shem/tui/agent_view_test.exs
git commit -m "feat: AgentView — extract from_events/1 as pure function; build/1 becomes wrapper"
```

---

## Task 3: `EventLog.HistoryScanner`

**Files:**
- Create: `lib/shem/event_log/history_scanner.ex`
- Create: `test/shem/event_log/history_scanner_test.exs`

### Background

`HistoryScanner.scan/0` lists all `.dets` files in the event log directory, skips any that belong to currently-active sessions (to avoid DETS lock conflicts), and calls `EventLog.read_session_events/1` for each remaining session. It folds the events into a `HistoryScanner.t()` summary struct. Results are sorted most-recent-first.

The tests write real DETS files directly to a temp dir (overriding `event_log_path`). Since `read_session_events` reads DETS directly from disk for non-active sessions, these test files are read correctly regardless of which `Store` the running EventLog GenServer uses.

- [ ] **Step 1: Create the test file**

Create `test/shem/event_log/history_scanner_test.exs`:

```elixir
defmodule Shem.EventLog.HistoryScannerTest do
  use ExUnit.Case, async: false

  alias Shem.EventLog.HistoryScanner
  alias Shem.EventLog.Event

  @base_path "tmp/test_scanner"

  setup do
    path = @base_path <> "_#{:erlang.unique_integer([:positive])}"
    File.mkdir_p!(path)
    orig_path = Application.get_env(:shem, :event_log_path, "tmp/test_events")
    Application.put_env(:shem, :event_log_path, path)

    on_exit(fn ->
      Application.put_env(:shem, :event_log_path, orig_path)
      File.rm_rf!(path)
    end)

    %{path: path}
  end

  defp write_session(session_id, events, path) do
    dets_file = Path.join(path, "#{session_id}.dets") |> String.to_charlist()
    table = :"test_scan_#{session_id}_#{:erlang.unique_integer([:positive])}"
    {:ok, tab} = :dets.open_file(table, file: dets_file, type: :set)
    for event <- events, do: :dets.insert(tab, {event.id, event})
    :dets.close(tab)
  end

  test "scan/0 returns empty list when directory has no dets files", %{path: _path} do
    assert HistoryScanner.scan() == []
  end

  test "scan/0 returns a summary for a done session", %{path: path} do
    sid = "ses_SCAN_DONE"
    write_session(sid, [
      Event.new(sid, :agent_started, %{task: "test scan task", model: :default, max_turns: 20}),
      Event.new(sid, :agent_done, %{content: "result", reason: :answer})
    ], path)

    [summary] = HistoryScanner.scan()
    assert summary.session_id == sid
    assert summary.task == "test scan task"
    assert summary.status == :done
    assert summary.turn_count == 0
  end

  test "scan/0 infers :error status from agent_error event", %{path: path} do
    sid = "ses_SCAN_ERR"
    write_session(sid, [
      Event.new(sid, :agent_started, %{task: "failing task", model: :default, max_turns: 20}),
      Event.new(sid, :agent_error, %{reason: "llm timeout"})
    ], path)

    [summary] = HistoryScanner.scan()
    assert summary.status == :error
  end

  test "scan/0 infers :unknown for sessions without done or error", %{path: path} do
    sid = "ses_SCAN_UNK"
    write_session(sid, [
      Event.new(sid, :agent_started, %{task: "interrupted", model: :default, max_turns: 20})
    ], path)

    [summary] = HistoryScanner.scan()
    assert summary.status == :unknown
  end

  test "scan/0 counts turn_count from agent_turn_completed events", %{path: path} do
    sid = "ses_SCAN_TURNS"
    write_session(sid, [
      Event.new(sid, :agent_started, %{task: "t", model: :default, max_turns: 20}),
      Event.new(sid, :agent_turn_completed, %{turn: 1}),
      Event.new(sid, :agent_turn_completed, %{turn: 2}),
      Event.new(sid, :agent_done, %{content: "done"})
    ], path)

    [summary] = HistoryScanner.scan()
    assert summary.turn_count == 2
  end

  test "scan/0 returns multiple sessions sorted most-recent-first", %{path: path} do
    sid_a = "ses_SCAN_A"
    sid_b = "ses_SCAN_B"

    write_session(sid_a, [
      Event.new(sid_a, :agent_started, %{task: "older", model: :default, max_turns: 20}),
      Event.new(sid_a, :agent_done, %{content: "done"})
    ], path)

    Process.sleep(5)

    write_session(sid_b, [
      Event.new(sid_b, :agent_started, %{task: "newer", model: :default, max_turns: 20}),
      Event.new(sid_b, :agent_done, %{content: "done"})
    ], path)

    [first, second] = HistoryScanner.scan()
    assert first.task == "newer"
    assert second.task == "older"
  end

  test "scan/0 skips corrupt/unreadable session files gracefully", %{path: path} do
    sid_bad = "ses_SCAN_BAD"
    File.write!(Path.join(path, "#{sid_bad}.dets"), "not a dets file at all")

    sid_good = "ses_SCAN_GOOD"
    write_session(sid_good, [
      Event.new(sid_good, :agent_started, %{task: "good", model: :default, max_turns: 20}),
      Event.new(sid_good, :agent_done, %{content: "done"})
    ], path)

    summaries = HistoryScanner.scan()
    assert length(summaries) == 1
    assert hd(summaries).session_id == sid_good
  end
end
```

- [ ] **Step 2: Run to verify tests fail**

```bash
mix test test/shem/event_log/history_scanner_test.exs 2>&1 | tail -10
```

Expected: failures with `module Shem.EventLog.HistoryScanner is not available`.

- [ ] **Step 3: Create `lib/shem/event_log/history_scanner.ex`**

```elixir
defmodule Shem.EventLog.HistoryScanner do
  alias Shem.EventLog

  @enforce_keys [:session_id]
  defstruct [:session_id, :task, :started_at, :status, :turn_count]

  @type status :: :done | :error | :running | :unknown

  @type t :: %__MODULE__{
          session_id: String.t(),
          task: String.t() | nil,
          started_at: DateTime.t() | nil,
          status: status(),
          turn_count: non_neg_integer()
        }

  @spec scan() :: [t()]
  def scan do
    path = event_log_path()
    active_ids = active_session_ids()

    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".dets"))
        |> Enum.map(&String.replace_suffix(&1, ".dets", ""))
        |> Enum.reject(&MapSet.member?(active_ids, &1))
        |> Enum.flat_map(&build_summary(&1))
        |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

      {:error, _} ->
        []
    end
  end

  defp event_log_path do
    Application.get_env(
      :shem,
      :event_log_path,
      Path.join([System.user_home!(), ".config", "shem", "lab", "events"])
    )
  end

  defp active_session_ids do
    case EventLog.list_sessions() do
      {:ok, sessions} ->
        sessions
        |> Enum.filter(&is_nil(&1.ended_at))
        |> Enum.map(& &1.id)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp build_summary(session_id) do
    try do
      case EventLog.read_session_events(session_id) do
        {:ok, events} ->
          [%__MODULE__{
            session_id: session_id,
            task: extract_task(events),
            started_at: extract_started_at(events),
            status: infer_status(events),
            turn_count: Enum.count(events, &(&1.type == :agent_turn_completed))
          }]

        _ ->
          []
      end
    catch
      :exit, _ -> []
    end
  end

  defp extract_task(events) do
    case Enum.find(events, &(&1.type == :agent_started)) do
      nil -> nil
      event -> event.payload[:task]
    end
  end

  defp extract_started_at([]), do: nil
  defp extract_started_at([first | _]), do: first.timestamp

  defp infer_status(events) do
    cond do
      Enum.any?(events, &(&1.type == :agent_done)) -> :done
      Enum.any?(events, &(&1.type == :agent_error)) -> :error
      true -> :unknown
    end
  end
end
```

- [ ] **Step 4: Run HistoryScanner tests**

```bash
mix test test/shem/event_log/history_scanner_test.exs 2>&1 | tail -10
```

Expected: all 7 tests pass.

- [ ] **Step 5: Run full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: 489 tests passing (482 + 7 new).

- [ ] **Step 6: Commit**

```bash
git add lib/shem/event_log/history_scanner.ex test/shem/event_log/history_scanner_test.exs
git commit -m "feat: HistoryScanner — discover and summarise past agent sessions from disk"
```

---

## Task 4: `Agent.resume/2`

**Files:**
- Modify: `lib/shem/agent_supervisor.ex`
- Modify: `lib/shem/agent.ex`
- Modify: `test/shem/agent_test.exs`

### Background

`AgentSupervisor.start_agent/2` currently generates its own `session_id`. A new `start_agent/3` overload accepts a caller-supplied `session_id` so the agent process resumes the existing DETS file. `Agent.resume/2` calls this overload; `Agent.Server.init` then finds the existing events via `Checkpoint.reconstruct`, appends `:agent_resumed`, and continues from the checkpoint.

- [ ] **Step 1: Write failing tests**

In `test/shem/agent_test.exs`, add a new describe block (look for the end of the file and insert before the closing `end`):

```elixir
describe "resume/2" do
  setup do
    Shem.LLM.StubTransport.Server.reset()
    :ok
  end

  test "returns {:ok, name} for a valid session_id and task" do
    sid = "ses_RESUME_#{System.unique_integer([:positive])}"
    {:ok, ^sid} = Shem.EventLog.start_session(sid)
    Shem.EventLog.append(sid, :agent_started, %{task: "original task", model: :default, max_turns: 20})
    Shem.EventLog.end_session(sid)

    Shem.LLM.StubTransport.Server.push_response(%{
      content: "resumed answer",
      tool_calls: []
    })

    assert {:ok, name} = Shem.Agent.resume(sid, "original task")
    assert is_binary(name)
    assert String.starts_with?(name, "agent_")

    Shem.Agent.stop(name)
  end

  test "started agent is queryable via status/1" do
    sid = "ses_RESUME_STATUS_#{System.unique_integer([:positive])}"
    {:ok, ^sid} = Shem.EventLog.start_session(sid)
    Shem.EventLog.append(sid, :agent_started, %{task: "status task", model: :default, max_turns: 20})
    Shem.EventLog.end_session(sid)

    Shem.LLM.StubTransport.Server.push_response(%{
      content: "done",
      tool_calls: []
    })

    {:ok, name} = Shem.Agent.resume(sid, "status task")
    assert {:ok, _status} = Shem.Agent.status(name)

    Shem.Agent.stop(name)
  end
end
```

- [ ] **Step 2: Run to verify tests fail**

```bash
mix test test/shem/agent_test.exs --only "resume" 2>&1 | tail -10
```

Expected: failures with `undefined function Shem.Agent.resume/2`.

- [ ] **Step 3: Add `start_agent/3` to `lib/shem/agent_supervisor.ex`**

Replace the existing `start_agent/2` with two functions:

```elixir
@spec start_agent(String.t(), Config.t()) :: Horde.DynamicSupervisor.on_start_child()
def start_agent(name, %Config{} = config) do
  start_agent(name, config, generate_session_id())
end

@spec start_agent(String.t(), Config.t(), String.t()) :: Horde.DynamicSupervisor.on_start_child()
def start_agent(name, %Config{} = config, session_id) do
  via = Shem.ProcessRegistry.via_tuple(name)

  child_spec = %{
    id: name,
    start: {Shem.Agent.Server, :start_link, [{name, config, session_id, [name: via]}]},
    restart: :temporary
  }

  Horde.DynamicSupervisor.start_child(__MODULE__, child_spec)
end
```

- [ ] **Step 4: Add `resume/2` to `lib/shem/agent.ex`**

After the existing `start_with_preset/2` function (around line 71), add:

```elixir
@spec resume(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
def resume(session_id, task) do
  with {:ok, preset} <- Shem.Agent.Preset.resolve("general") do
    config = %Config{
      task: task,
      system_prompt: preset.system_prompt,
      tools: [],
      max_turns: 20
    }

    name = "agent_" <> Base.encode16(:crypto.strong_rand_bytes(4))

    case AgentSupervisor.start_agent(name, config, session_id) do
      {:ok, _pid} -> {:ok, name}
      error -> error
    end
  end
end
```

- [ ] **Step 5: Run agent tests**

```bash
mix test test/shem/agent_test.exs 2>&1 | tail -10
```

Expected: all agent tests pass including the two new resume tests.

- [ ] **Step 6: Run full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: 491 tests passing.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/agent_supervisor.ex lib/shem/agent.ex test/shem/agent_test.exs
git commit -m "feat: Agent — add resume/2; AgentSupervisor.start_agent/3 accepts caller-supplied session_id"
```

---

## Task 5: `TUI.Views.History`

**Files:**
- Create: `lib/shem/tui/views/history.ex`
- Create: `test/shem/tui/views/history_test.exs`

### Background

Layout A (split list + detail). Left panel (size 4): session list with cursor. Right panel (size 8): `AgentView`-style detail. Bottom: key hints. All rendering is pure — it takes the model and returns a view tree.

- [ ] **Step 1: Write render tests**

Create `test/shem/tui/views/history_test.exs`:

```elixir
defmodule Shem.TUI.Views.HistoryTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.Views.History
  alias Shem.EventLog.HistoryScanner
  alias Shem.TUI.AgentView

  defp base_model do
    %{
      history_sessions: [],
      history_cursor: 0,
      history_detail: nil
    }
  end

  defp summary(opts \\ []) do
    %HistoryScanner{
      session_id: Keyword.get(opts, :session_id, "ses_TEST"),
      task: Keyword.get(opts, :task, "test task"),
      started_at: Keyword.get(opts, :started_at, DateTime.utc_now()),
      status: Keyword.get(opts, :status, :done),
      turn_count: Keyword.get(opts, :turn_count, 3)
    }
  end

  test "render/1 does not raise for empty session list" do
    model = base_model()
    assert is_map(History.render(model))
  end

  test "render/1 does not raise for populated session list" do
    model = %{base_model() | history_sessions: [summary()], history_cursor: 0}
    assert is_map(History.render(model))
  end

  test "render/1 does not raise with history_detail populated" do
    model = %{
      base_model()
      | history_sessions: [summary()],
        history_cursor: 0,
        history_detail: %AgentView{}
    }
    assert is_map(History.render(model))
  end

  test "render/1 does not raise when cursor is beyond session list" do
    model = %{base_model() | history_sessions: [summary()], history_cursor: 5}
    assert is_map(History.render(model))
  end
end
```

- [ ] **Step 2: Run to verify tests fail**

```bash
mix test test/shem/tui/views/history_test.exs 2>&1 | tail -10
```

Expected: failures with `module Shem.TUI.Views.History is not available`.

- [ ] **Step 3: Create `lib/shem/tui/views/history.ex`**

```elixir
defmodule Shem.TUI.Views.History do
  import Ratatouille.View
  import Ratatouille.Constants, only: [color: 1, attribute: 1]

  def render(model) do
    view do
      row do
        column(size: 4) do
          render_session_list(model)
        end

        column(size: 8) do
          render_session_detail(model)
        end
      end

      row do
        column(size: 12) do
          panel(title: "h/Esc=back  ↑↓=navigate  r=resume", color: color(:white)) do
            label(content: "", color: color(:white))
          end
        end
      end
    end
  end

  defp render_session_list(%{history_sessions: [], history_cursor: _}) do
    panel(title: "Session History", color: color(:yellow)) do
      label(content: "No past sessions found.", color: color(:yellow))
    end
  end

  defp render_session_list(%{history_sessions: sessions, history_cursor: cursor}) do
    panel(title: "Session History (#{length(sessions)})", color: color(:yellow)) do
      for {summary, i} <- Enum.with_index(sessions) do
        selected = i == cursor
        marker = if selected, do: "●", else: "○"
        task = truncate(summary.task || "(no task)", 22)
        meta = "  #{status_abbrev(summary.status)}·#{summary.turn_count}t·#{format_ago(summary.started_at)}"

        label(
          content: "#{marker} #{String.pad_trailing(task, 22)}",
          color: if(selected, do: color(:cyan), else: color(:white)),
          attributes: if(selected, do: [attribute(:bold)], else: [])
        )

        label(
          content: meta,
          color: status_color(summary.status)
        )
      end
    end
  end

  defp render_session_detail(%{history_detail: nil, history_sessions: []}) do
    panel(title: "Session Detail", color: color(:cyan)) do
      label(content: "No sessions found.", color: color(:white))
    end
  end

  defp render_session_detail(%{history_detail: nil, history_sessions: sessions, history_cursor: cursor}) do
    summary = Enum.at(sessions, cursor)
    title = if summary, do: "#{summary.session_id} · loading...", else: "Session Detail"

    panel(title: title, color: color(:cyan)) do
      label(content: "Loading session detail...", color: color(:white))
    end
  end

  defp render_session_detail(%{history_detail: view, history_sessions: sessions, history_cursor: cursor}) do
    summary = Enum.at(sessions, cursor)
    title = if summary, do: "#{summary.session_id} · #{summary.task || "(no task)"}", else: "Session Detail"

    status_str =
      case view.status do
        :done -> "done"
        :error -> "error"
        :running -> "running"
        _ -> "unknown"
      end

    history_line =
      view.history
      |> Enum.map(fn %{turn: t, tool: tool} ->
        if tool, do: "t#{t}:#{tool}", else: "t#{t}:done"
      end)
      |> Enum.join("  ·  ")

    panel(title: title, color: status_color_for(view.status)) do
      label(
        content: "STATUS",
        attributes: [attribute(:bold)],
        color: color(:white)
      )
      label(content: status_str, color: status_color_for(view.status))
      label(content: "")

      label(
        content: "TURN HISTORY",
        attributes: [attribute(:bold)],
        color: color(:white)
      )
      label(
        content: if(history_line == "", do: "no completed turns", else: history_line),
        color: color(:white)
      )
      label(content: "")

      label(
        content: "LAST TOOL CALL",
        attributes: [attribute(:bold)],
        color: color(:white)
      )

      case view.last_tool_call do
        nil ->
          label(content: "none", color: color(:white))

        tc ->
          label(content: "→ #{tc.name}", color: color(:green))

          if tc.result do
            label(content: "← #{truncate(tc.result, 100)}", color: color(:white))
          end
      end

      label(content: "")

      label(
        content: "REASONING",
        attributes: [attribute(:bold)],
        color: color(:white)
      )
      label(
        content: truncate(view.current_reasoning || "—", 180),
        color: color(:cyan)
      )
    end
  end

  defp status_abbrev(:done), do: "✓"
  defp status_abbrev(:error), do: "✗"
  defp status_abbrev(:running), do: "▶"
  defp status_abbrev(:unknown), do: "?"

  defp status_color(:done), do: color(:green)
  defp status_color(:error), do: color(:red)
  defp status_color(:running), do: color(:cyan)
  defp status_color(:unknown), do: color(:white)

  defp status_color_for(:done), do: color(:green)
  defp status_color_for(:error), do: color(:red)
  defp status_color_for(:running), do: color(:cyan)
  defp status_color_for(_), do: color(:white)

  defp format_ago(nil), do: "—"

  defp format_ago(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "…"
end
```

- [ ] **Step 4: Run History view tests**

```bash
mix test test/shem/tui/views/history_test.exs 2>&1 | tail -10
```

Expected: all 4 tests pass.

- [ ] **Step 5: Run full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: 495 tests passing.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/views/history.ex test/shem/tui/views/history_test.exs
git commit -m "feat: Views.History — split list+detail TUI view for session history browser"
```

---

## Task 6: `App` History Mode Wiring

**Files:**
- Modify: `lib/shem/tui/app.ex`
- Modify: `test/shem/tui/app_test.exs`

### Background

Wire up: new model fields, `h` key enters/exits history mode, arrow keys move cursor, `r` resumes selected session, render dispatch, `load_history_detail/2` helper.

Arrow key constants from ex_termbox: `@arrow_up 65517`, `@arrow_down 65516`.

- [ ] **Step 1: Write failing tests**

Add to `test/shem/tui/app_test.exs`, as a new describe block:

```elixir
describe "history mode" do
  alias Shem.EventLog.HistoryScanner

  defp history_summary(opts \\ []) do
    %HistoryScanner{
      session_id: Keyword.get(opts, :session_id, "ses_HIST_TEST"),
      task: Keyword.get(opts, :task, "hist task"),
      started_at: Keyword.get(opts, :started_at, DateTime.utc_now()),
      status: Keyword.get(opts, :status, :done),
      turn_count: Keyword.get(opts, :turn_count, 2)
    }
  end

  test "h key enters :history mode" do
    model = App.init(%{})
    updated = App.update(model, {:event, %{ch: ?h, key: 0}})
    assert updated.mode == :history
  end

  test "h key in :history mode returns to :interactive" do
    model = App.init(%{}) |> Map.put(:mode, :history)
    updated = App.update(model, {:event, %{ch: ?h, key: 0}})
    assert updated.mode == :interactive
  end

  test "Esc in :history mode returns to :interactive" do
    model = App.init(%{}) |> Map.put(:mode, :history)
    updated = App.update(model, {:event, %{key: 27}})
    assert updated.mode == :interactive
  end

  test "arrow_down increments history_cursor" do
    summaries = [history_summary(session_id: "a"), history_summary(session_id: "b")]
    model = App.init(%{}) |> Map.merge(%{mode: :history, history_sessions: summaries, history_cursor: 0})
    updated = App.update(model, {:event, %{key: 65516}})
    assert updated.history_cursor == 1
  end

  test "arrow_down clamps at last session" do
    summaries = [history_summary()]
    model = App.init(%{}) |> Map.merge(%{mode: :history, history_sessions: summaries, history_cursor: 0})
    updated = App.update(model, {:event, %{key: 65516}})
    assert updated.history_cursor == 0
  end

  test "arrow_up decrements history_cursor" do
    summaries = [history_summary(session_id: "a"), history_summary(session_id: "b")]
    model = App.init(%{}) |> Map.merge(%{mode: :history, history_sessions: summaries, history_cursor: 1})
    updated = App.update(model, {:event, %{key: 65517}})
    assert updated.history_cursor == 0
  end

  test "arrow_up clamps at 0" do
    summaries = [history_summary()]
    model = App.init(%{}) |> Map.merge(%{mode: :history, history_sessions: summaries, history_cursor: 0})
    updated = App.update(model, {:event, %{key: 65517}})
    assert updated.history_cursor == 0
  end

  test "h key does not enter history when command_buffer is non-empty" do
    model = App.init(%{}) |> Map.put(:command_buffer, "/foo")
    updated = App.update(model, {:event, %{ch: ?h, key: 0}})
    assert updated.mode == :interactive
    assert updated.command_buffer == "/foo" <> <<(?h)::utf8>>
  end
end
```

- [ ] **Step 2: Run to verify tests fail**

```bash
mix test test/shem/tui/app_test.exs --only "history mode" 2>&1 | tail -15
```

Expected: mix of failures — some will fail on missing model fields, others on wrong mode.

- [ ] **Step 3: Add new model fields to `App.init/1` in `lib/shem/tui/app.ex`**

In the `init/1` function, add three fields to the returned map (after `multiline_target: nil`):

```elixir
history_sessions: [],
history_cursor: 0,
history_detail: nil
```

- [ ] **Step 4: Add arrow key module attributes in `lib/shem/tui/app.ex`**

After the existing `@tab 9` module attribute line, add:

```elixir
@arrow_up 65517
@arrow_down 65516
```

- [ ] **Step 5: Add history mode key handlers to `App.update/2` in `lib/shem/tui/app.ex`**

Add these clauses inside `update/2` — insert them **before** the `# --- Normal mode ---` comment block:

```elixir
# --- History mode ---
{:event, %{ch: ?h, key: 0}} when model.mode == :history ->
  %{model | mode: :interactive}

{:event, %{key: @esc}} when model.mode == :history ->
  %{model | mode: :interactive}

{:event, %{key: @arrow_up}} when model.mode == :history ->
  new_cursor = max(0, model.history_cursor - 1)
  %{model | history_cursor: new_cursor, history_detail: load_history_detail(model.history_sessions, new_cursor)}

{:event, %{key: @arrow_down}} when model.mode == :history ->
  new_cursor = min(max(0, length(model.history_sessions) - 1), model.history_cursor + 1)
  %{model | history_cursor: new_cursor, history_detail: load_history_detail(model.history_sessions, new_cursor)}

{:event, %{ch: ?r, key: 0}} when model.mode == :history ->
  case Enum.at(model.history_sessions, model.history_cursor) do
    nil ->
      model

    %{session_id: session_id, task: task} when not is_nil(task) ->
      case Shem.Agent.resume(session_id, task) do
        {:ok, name} ->
          %{model | mode: :interactive, focused_agent: name, command_error: nil, command_output: nil}

        {:error, reason} ->
          %{model | command_error: "resume failed: #{inspect(reason)}"}
      end

    _ ->
      %{model | command_error: "cannot resume: session has no task"}
  end

{:event, _} when model.mode == :history ->
  model
```

- [ ] **Step 6: Add `h` key handler in the normal mode block of `App.update/2`**

Find the existing `{:event, %{ch: ?i, key: 0}} when model.command_buffer == "" ->` clause (the one that switches to `:interactive`), and add a new clause immediately after it:

```elixir
{:event, %{ch: ?h, key: 0}} when model.command_buffer == "" ->
  sessions = safe_scan_history()
  detail = load_history_detail(sessions, 0)
  %{model | mode: :history, history_sessions: sessions, history_cursor: 0, history_detail: detail}
```

- [ ] **Step 7: Add `render/1` clause for `:history` in `lib/shem/tui/app.ex`**

In the `render/1` function, add a new clause:

```elixir
:history -> Shem.TUI.Views.History.render(model)
```

And add the alias at the top of the `render/1` match (or add it to the existing alias block at the top of the module):

```elixir
alias Shem.TUI.Views.{Dashboard, Interactive, History}
```

- [ ] **Step 8: Add private helpers to `lib/shem/tui/app.ex`**

Add these private functions (near the other `safe_*` helpers at the bottom of the module):

```elixir
defp load_history_detail([], _cursor), do: nil

defp load_history_detail(sessions, cursor) do
  case Enum.at(sessions, cursor) do
    nil ->
      nil

    %{session_id: session_id} ->
      case Shem.EventLog.read_session_events(session_id) do
        {:ok, events} -> Shem.TUI.AgentView.from_events(events)
        _ -> nil
      end
  end
end

defp safe_scan_history do
  try do
    Shem.EventLog.HistoryScanner.scan()
  catch
    :exit, _ -> []
  end
end
```

- [ ] **Step 9: Run App history mode tests**

```bash
mix test test/shem/tui/app_test.exs --only "history mode" 2>&1 | tail -15
```

Expected: all 8 new tests pass.

- [ ] **Step 10: Run full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass (target: ~503 total).

- [ ] **Step 11: Commit**

```bash
git add lib/shem/tui/app.ex test/shem/tui/app_test.exs
git commit -m "feat: App — history mode wiring; h=enter/exit, arrow keys navigate, r=resume"
```

---

## Done

Run the full suite one final time to confirm all tests are green:

```bash
mix test 2>&1 | tail -5
```

Then verify the feature by running the app:

```bash
mix run --no-halt
```

Press `h` to enter history mode. Arrow up/down to navigate sessions. `r` to resume a session. `h` or Esc to exit.
