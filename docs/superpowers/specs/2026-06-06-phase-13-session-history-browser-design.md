# Phase 13 — Session History Browser Design

## Overview

Phase 13 adds a session history browser to the Shem TUI. Users press `h` to enter a split-panel history mode, navigate past agent sessions with arrow keys, inspect turn-by-turn detail on the right, and press `r` to resume any session with a new agent.

EventLog already persists everything to DETS files. The missing piece is discovery (past sessions from previous runs are not loaded into the running EventLog GenServer) and TUI plumbing to surface and navigate them.

---

## Architecture

Five focused components, each with a single responsibility.

### 1. `EventLog.read_session_events/1`

New public API on the existing `Shem.EventLog` GenServer. Reads events from any session regardless of its lifecycle state:

- **Active** (open DETS handle in current runtime) — reads from the open handle.
- **Ended** (session was closed in current runtime, handle is nil) — re-opens the DETS file temporarily, reads all, closes.
- **Past** (session from a previous run, not in GenServer state at all) — opens from disk, reads all, closes.

All DETS access remains inside the GenServer, preventing concurrent-open conflicts.

```elixir
@spec read_session_events(String.t()) :: {:ok, [Event.t()]} | {:error, :not_found}
def read_session_events(session_id)
```

Returns `{:error, :not_found}` if the DETS file does not exist on disk.

### 2. `EventLog.HistoryScanner`

Pure module (no GenServer). Discovers and summarises all past sessions.

```elixir
defmodule Shem.EventLog.HistoryScanner do
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
  def scan()
end
```

`scan/0` lists all `*.dets` files in the event log directory, extracts the session_id from each filename, calls `EventLog.read_session_events/1`, and folds events into a `HistoryScanner` summary struct. Results are sorted most-recent-first by `started_at`.

Status inference from events:
- `:agent_done` present → `:done`
- `:agent_error` present → `:error`
- Session is in current EventLog active sessions (has live handle) → `:running`
- None of the above → `:unknown` (session was interrupted)

Task is extracted from the `:agent_started` event payload (`:task` key). `started_at` is the timestamp of the first event.

### 3. `AgentView` refactor

`AgentView.build/1` is split into two functions:

```elixir
@spec build(String.t()) :: {:ok, t()} | :not_found
def build(session_id)  # existing — calls read_session_events, delegates to from_events/1

@spec from_events([Event.t()]) :: t()
def from_events(events)  # new pure function — contains all fold logic
```

The history browser calls `from_events/1` with pre-fetched events. The live interactive view continues using `build/1`. All existing fold logic moves to `from_events/1` unchanged.

### 4. `Agent.resume/2`

New public function on `Shem.Agent`. Starts a new agent process that continues an existing session.

```elixir
@spec resume(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
def resume(session_id, task)
```

Builds a `:general` preset config with the given task, then starts the agent with the provided `session_id`. `Agent.Server.init/1` calls `Checkpoint.reconstruct(session_id)`, finds the existing checkpoint, and emits `:agent_resumed` — the existing resume path runs unchanged.

### 5. `Shem.TUI.Views.History`

New view module. Layout A (split list + detail):

```
┌─────────────────────────────────────────────────────────────────┐
│  Session History (N)          │  <session_id> · <task>          │
│                               │                                  │
│  ● ses_A1B2  summarise logs   │  STATUS  TURN HISTORY            │
│    done · 4 turns · 2h ago    │  t1:shell · t2:shell · t3:done  │
│                               │                                  │
│  ○ ses_C3D4  write tests      │  FINAL ANSWER                   │
│    error · 2 turns · 5h ago   │  Found 3 anomalies...           │
│                               │                                  │
│  ○ ses_E5F6  explore repo     │  LAST TOOL CALL                 │
│    done · 7 turns · 1d ago    │  → shell                        │
│                               │    ← output...                  │
├───────────────────────────────┴──────────────────────────────────┤
│  ↑↓=navigate  r=resume  h/Esc=back                              │
└─────────────────────────────────────────────────────────────────┘
```

- Left panel (column size 4): session list, one line per session, cursor session highlighted with `●` and cyan color. Status colors: green for `:done`, red for `:error`, cyan for `:running`, white for `:unknown`.
- Right panel (column size 8): full AgentView-style detail for the cursor session, using `AgentView.from_events/1` with events fetched on cursor selection. Shows task, status, turn history line, final answer (from `:agent_done` payload `.content`), and last tool call.
- Bottom bar: key hints.

---

## TUI Changes (`App`)

### New model fields

```elixir
history_sessions: [],   # [HistoryScanner.t()]
history_cursor: 0,      # integer index into history_sessions
history_detail: nil,    # AgentView.t() | nil — view for cursor session
```

### Key bindings

| Key | Context | Action |
|-----|---------|--------|
| `h` | command buffer empty, any mode | Enter `:history` mode; call `HistoryScanner.scan/0`; reset cursor to 0; load detail for first session |
| `h` or `Esc` | `:history` mode | Return to `:interactive` mode |
| Arrow up | `:history` mode | Decrement cursor (clamp at 0); reload detail |
| Arrow down | `:history` mode | Increment cursor (clamp at length-1); reload detail |
| `r` | `:history` mode | Call `Agent.resume(session_id, task)` for cursor session; switch to `:interactive`; set `focused_agent` to new agent name |

### Tick behaviour

No scan on `:tick` in history mode — it is a snapshot view. The scan runs once on entry. If the user wants a fresh scan, they exit and re-enter with `h`.

### Render dispatch

```elixir
def render(model) do
  case model.mode do
    :dashboard -> Dashboard.render(model)
    :interactive -> Interactive.render(model)
    :multiline_input -> Interactive.render(model)
    :history -> History.render(model)   # new
  end
end
```

---

## Data Flow

1. User presses `h` → `App.update/2` calls `HistoryScanner.scan/0`, stores result in `history_sessions`, loads `AgentView.from_events/1` for session at cursor 0 into `history_detail`, enters `:history` mode.
2. User navigates with arrow keys → cursor index updates, `history_detail` reloads from `EventLog.read_session_events/1` + `AgentView.from_events/1`.
3. User presses `r` → `Agent.resume(session_id, task)` called, returns `{:ok, name}`, model switches to `:interactive` with `focused_agent: name`.
4. User presses `h` or `Esc` → model switches to `:interactive`, history fields unchanged (stale until next entry).

---

## Error Handling

- `HistoryScanner.scan/0` wraps each session read in a `try/catch`; corrupt or unreadable DETS files are skipped silently.
- If `scan/0` returns `[]`, History view shows "No past sessions found."
- If detail load fails for a session, right panel shows "Session detail unavailable." — does not crash the view.
- `Agent.resume/2` failure (e.g., agent supervisor not running) sets `command_error` and stays in `:history` mode.

---

## Testing

### `EventLog.read_session_events/1`
Three unit tests using `FakeStore`:
1. Active session — reads from open handle.
2. Ended session — handle is nil; verify DETS re-opened and events returned.
3. Not-found session — returns `{:error, :not_found}`.

### `EventLog.HistoryScanner`
Tests use a temp directory with DETS files seeded via `FakeStore`:
1. `scan/0` returns one `HistoryScanner` struct per session file.
2. Status inference: `:done`, `:error`, `:unknown` from event presence.
3. Results sorted most-recent-first.
4. Corrupt/missing file skipped without crash.

### `AgentView.from_events/1`
Port existing `AgentView` tests to call `from_events/1` directly. `build/1` wrapper needs no separate test.

### `Agent.resume/2`
- Verify `EventLog.start_session` called with given session_id.
- Verify `:agent_resumed` event appended (via `StubTransport`).
- Verify returned name is usable as `focused_agent`.

### `App` history mode
Unit tests for all key bindings:
- `h` entering `:history`, `history_sessions` populated, cursor at 0.
- `h`/`Esc` returning to `:interactive`.
- Arrow up/down cursor movement with clamping.
- `r` calling `Agent.resume/2`, mode switching to `:interactive`.

### `Views.History` render
- Empty `history_sessions` renders "No past sessions found."
- Populated list renders session rows with correct status colors.
- Cursor session highlighted; detail panel shows AgentView content.

---

## Files Changed

| File | Change |
|------|--------|
| `lib/shem/event_log.ex` | Add `read_session_events/1` |
| `lib/shem/event_log/history_scanner.ex` | New module |
| `lib/shem/tui/agent_view.ex` | Extract `from_events/1`; `build/1` becomes wrapper |
| `lib/shem/agent.ex` | Add `resume/2` |
| `lib/shem/tui/app.ex` | New model fields, history key bindings, render dispatch |
| `lib/shem/tui/views/history.ex` | New view module |
| `test/shem/event_log_test.exs` | `read_session_events/1` tests |
| `test/shem/event_log/history_scanner_test.exs` | New test module |
| `test/shem/tui/agent_view_test.exs` | Port to `from_events/1` |
| `test/shem/agent_test.exs` | `resume/2` tests |
| `test/shem/tui/app_test.exs` | History mode key binding tests |
| `test/shem/tui/views/history_test.exs` | New test module |
