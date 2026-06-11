# Phase 32 — Timeline Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a web-based timeline viewer at `/timeline` that lists all sessions, shows a per-session event timeline with expandable cards, and lets users fork any LLM call response into a new chat session.

**Architecture:** Separate `timeline.html` page sharing `app.js` with `index.html`. Three `Alpine.data()` named components (`sessionList`, `eventTimeline`, `forkModal`) registered in `app.js`. New REST handler `Shem.REST.Handlers.Sessions` with three routes wired into the existing REST router. Fork creates a new EventLog session by copying events up to the branch point, then navigates to the chat UI via `?resume=<session_id>`.

**Tech Stack:** Elixir/OTP, Plug, Alpine.js (via `Alpine.data()`), Jason, `EventLog.read_session_events/1`, `HistoryScanner.scan/0`, `Agent.resume/2`

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `lib/shem/rest/handlers/sessions.ex` | GET /api/sessions, GET /api/sessions/:id/events, POST /api/sessions/:id/fork |
| Create | `test/shem/rest/sessions_test.exs` | Tests for all three sessions routes |
| Create | `priv/static/timeline.html` | Two-panel timeline UI wired to Alpine components |
| Modify | `lib/shem/rest/router.ex` | Add `forward "/sessions"` |
| Modify | `lib/shem/http/router.ex` | Add `GET /timeline` route |
| Modify | `lib/shem/rest/handlers/agents.ex` | Support `resume_session_id` in `POST /` |
| Modify | `test/shem/rest/agents_test.exs` | Test resume_session_id path |
| Modify | `priv/static/app.js` | Add `Alpine.data('sessionList')`, `Alpine.data('eventTimeline')`, `Alpine.data('forkModal')` |
| Modify | `priv/static/index.html` | Add Timeline nav link; handle `?resume` on init |

---

## Task 1: Sessions handler scaffold + GET /api/sessions

**Files:**
- Create: `lib/shem/rest/handlers/sessions.ex`
- Create: `test/shem/rest/sessions_test.exs`
- Modify: `lib/shem/rest/router.ex`

- [ ] **Step 1: Wire the route in the REST router**

In `lib/shem/rest/router.ex`, add the forward before the catch-all:

```elixir
forward "/sessions", to: Shem.REST.Handlers.Sessions
```

Full file after change:

```elixir
defmodule Shem.REST.Router do
  use Plug.Router

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["*/*"]

  plug :match
  plug :dispatch

  forward "/agents", to: Shem.REST.Handlers.Agents
  forward "/presets", to: Shem.REST.Handlers.Presets
  forward "/routes", to: Shem.REST.Handlers.Routes
  forward "/sessions", to: Shem.REST.Handlers.Sessions

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end
end
```

- [ ] **Step 2: Write the failing test for GET /api/sessions**

Create `test/shem/rest/sessions_test.exs`:

```elixir
defmodule Shem.REST.SessionsTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Shem.REST.Router
  alias Shem.EventLog

  @opts Router.init([])

  defp get_path(path) do
    conn(:get, path) |> Router.call(@opts)
  end

  defp post_json(path, body) do
    encoded = Jason.encode!(body)
    conn(:post, path, encoded)
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  # GET /sessions ──────────────────────────────────────────────────────────────

  test "GET /sessions returns a list" do
    conn = get_path("/sessions")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_list(body)
  end

  test "GET /sessions includes an active session as active: true with status running" do
    {:ok, session_id} = EventLog.start_session()
    EventLog.append(session_id, :agent_started, %{task: "test task", preset: "general"})

    conn = get_path("/sessions")
    assert conn.status == 200
    sessions = Jason.decode!(conn.resp_body)

    found = Enum.find(sessions, &(&1["session_id"] == session_id))
    assert found != nil
    assert found["active"] == true
    assert found["status"] == "running"
    assert found["task"] == "test task"

    EventLog.end_session(session_id)
  end

  test "GET /sessions session entries have required fields" do
    {:ok, session_id} = EventLog.start_session()
    EventLog.append(session_id, :agent_started, %{task: "field check", preset: "coder"})

    conn = get_path("/sessions")
    sessions = Jason.decode!(conn.resp_body)
    found = Enum.find(sessions, &(&1["session_id"] == session_id))

    assert Map.has_key?(found, "session_id")
    assert Map.has_key?(found, "task")
    assert Map.has_key?(found, "started_at")
    assert Map.has_key?(found, "status")
    assert Map.has_key?(found, "turn_count")
    assert Map.has_key?(found, "active")

    EventLog.end_session(session_id)
  end
end
```

- [ ] **Step 3: Run the test to confirm it fails**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/rest/sessions_test.exs 2>&1 | tail -20
```

Expected: compile error or `** (UndefinedFunctionError)` — handler does not exist yet.

- [ ] **Step 4: Create the sessions handler with GET /api/sessions**

Create `lib/shem/rest/handlers/sessions.ex`:

```elixir
defmodule Shem.REST.Handlers.Sessions do
  use Plug.Router

  alias Shem.EventLog
  alias Shem.EventLog.HistoryScanner

  plug :match
  plug :dispatch

  get "/" do
    sessions = list_all_sessions()
    send_json(conn, 200, sessions)
  end

  get "/:id/events" do
    case EventLog.read_session_events(id) do
      {:ok, events} ->
        send_json(conn, 200, Enum.map(events, &format_event/1))

      {:error, _} ->
        send_json(conn, 404, %{error: "session not found"})
    end
  end

  post "/:id/fork" do
    fork_event_id = Map.get(conn.body_params, "fork_event_id")
    alt_response = Map.get(conn.body_params, "alt_response")

    with {:ok, events} <- EventLog.read_session_events(id),
         {:ok, fork_event} <- find_fork_event(events, fork_event_id),
         {:ok, new_session_id} <- build_fork(events, fork_event, alt_response) do
      send_json(conn, 201, %{session_id: new_session_id})
    else
      {:error, :not_found} -> send_json(conn, 404, %{error: "session not found"})
      {:error, :fork_event_not_found} -> send_json(conn, 422, %{error: "fork_event_id not found in session"})
      {:error, :not_llm_call} -> send_json(conn, 422, %{error: "fork_event_id must point to an llm_call_completed event"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp list_all_sessions do
    {:ok, in_memory} = EventLog.list_sessions()

    active_ids =
      in_memory
      |> Enum.filter(&is_nil(&1.ended_at))
      |> Enum.map(& &1.id)
      |> MapSet.new()

    active =
      in_memory
      |> Enum.filter(&is_nil(&1.ended_at))
      |> Enum.map(&format_active_session/1)

    historical =
      HistoryScanner.scan()
      |> Enum.reject(&MapSet.member?(active_ids, &1.session_id))
      |> Enum.map(&format_historical_session/1)

    (active ++ historical)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  defp format_active_session(session) do
    # Read events to get task and turn_count
    {task, turn_count} =
      case EventLog.read_session_events(session.id) do
        {:ok, events} ->
          task =
            events
            |> Enum.find(&(&1.type == :agent_started))
            |> case do
              nil -> nil
              e -> e.payload[:task]
            end

          turns = Enum.count(events, &(&1.type == :agent_turn_completed))
          {task, turns}

        _ ->
          {nil, 0}
      end

    %{
      session_id: session.id,
      task: task,
      started_at: session.started_at,
      status: "running",
      turn_count: turn_count,
      active: true
    }
  end

  defp format_historical_session(%HistoryScanner{} = s) do
    status =
      case s.status do
        :done -> "done"
        :error -> "error"
        :running -> "running"
        _ -> "unknown"
      end

    %{
      session_id: s.session_id,
      task: s.task,
      started_at: s.started_at,
      status: status,
      turn_count: s.turn_count,
      active: false
    }
  end

  defp format_event(event) do
    %{
      id: event.id,
      type: event.type,
      timestamp: event.timestamp,
      parent_id: event.parent_id,
      payload: event.payload
    }
  end

  defp find_fork_event(events, fork_event_id) do
    case Enum.find(events, &(&1.id == fork_event_id)) do
      nil -> {:error, :fork_event_not_found}
      event when event.type == :llm_call_completed -> {:ok, event}
      _event -> {:error, :not_llm_call}
    end
  end

  defp build_fork(events, fork_event, alt_response) do
    {:ok, new_session_id} = EventLog.start_session()

    events_before = Enum.take_while(events, &(&1.id != fork_event.id))

    Enum.each(events_before, fn event ->
      EventLog.append(new_session_id, event.type, event.payload)
    end)

    fork_payload =
      if alt_response && alt_response != "" do
        Map.put(fork_event.payload, :content, alt_response)
      else
        fork_event.payload
      end

    EventLog.append(new_session_id, :llm_call_completed, fork_payload)
    {:ok, new_session_id}
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
```

- [ ] **Step 5: Run the GET /api/sessions tests**

```bash
mix test test/shem/rest/sessions_test.exs --only-failing 2>&1 | tail -30
```

Expected: the three GET /sessions tests pass. The events and fork tests fail with "no route" (not defined yet — that's fine).

- [ ] **Step 6: Commit**

```bash
git add lib/shem/rest/handlers/sessions.ex lib/shem/rest/router.ex test/shem/rest/sessions_test.exs
git commit -m "feat: Sessions handler scaffold + GET /api/sessions"
```

---

## Task 2: GET /api/sessions/:id/events

The handler code was already added in Task 1. This task adds the tests.

**Files:**
- Modify: `test/shem/rest/sessions_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/rest/sessions_test.exs` (after the GET /sessions tests):

```elixir
  # GET /sessions/:id/events ───────────────────────────────────────────────────

  test "GET /sessions/:id/events returns 404 for unknown session" do
    conn = get_path("/sessions/nonexistent_session_id_xyz/events")
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] =~ "not found"
  end

  test "GET /sessions/:id/events returns event list for a known session" do
    {:ok, session_id} = EventLog.start_session()
    EventLog.append(session_id, :agent_started, %{task: "events test", preset: "general"})
    EventLog.append(session_id, :llm_call_completed, %{content: "hello", tokens_used: 10, latency_ms: 500, model: "test"})

    conn = get_path("/sessions/#{session_id}/events")
    assert conn.status == 200
    events = Jason.decode!(conn.resp_body)

    assert is_list(events)
    assert length(events) == 2

    first = hd(events)
    assert first["type"] == "agent_started"
    assert Map.has_key?(first, "id")
    assert Map.has_key?(first, "timestamp")
    assert Map.has_key?(first, "payload")

    EventLog.end_session(session_id)
  end

  test "GET /sessions/:id/events events are in chronological order" do
    {:ok, session_id} = EventLog.start_session()
    EventLog.append(session_id, :agent_started, %{task: "order test"})
    EventLog.append(session_id, :agent_turn_completed, %{turn: 1})
    EventLog.append(session_id, :agent_done, %{content: "done"})

    conn = get_path("/sessions/#{session_id}/events")
    events = Jason.decode!(conn.resp_body)

    types = Enum.map(events, & &1["type"])
    assert types == ["agent_started", "agent_turn_completed", "agent_done"]

    EventLog.end_session(session_id)
  end
```

- [ ] **Step 2: Run to confirm tests pass**

```bash
mix test test/shem/rest/sessions_test.exs 2>&1 | tail -20
```

Expected: all GET /sessions and GET /sessions/:id/events tests pass. Fork tests still pending.

- [ ] **Step 3: Commit**

```bash
git add test/shem/rest/sessions_test.exs
git commit -m "test: GET /api/sessions/:id/events"
```

---

## Task 3: POST /api/sessions/:id/fork

The handler code was added in Task 1. This task adds tests for the fork endpoint.

**Files:**
- Modify: `test/shem/rest/sessions_test.exs`

- [ ] **Step 1: Write the fork tests**

Add to `test/shem/rest/sessions_test.exs`:

```elixir
  # POST /sessions/:id/fork ────────────────────────────────────────────────────

  test "POST /sessions/:id/fork returns 404 for unknown session" do
    conn = post_json("/sessions/nonexistent_xyz/fork", %{fork_event_id: "evt_000"})
    assert conn.status == 404
  end

  test "POST /sessions/:id/fork returns 422 when fork_event_id not in session" do
    {:ok, session_id} = EventLog.start_session()
    EventLog.append(session_id, :agent_started, %{task: "fork test"})

    conn = post_json("/sessions/#{session_id}/fork", %{fork_event_id: "evt_DOESNOTEXIST"})
    assert conn.status == 422
    body = Jason.decode!(conn.resp_body)
    assert body["error"] =~ "not found"

    EventLog.end_session(session_id)
  end

  test "POST /sessions/:id/fork returns 422 when event is not llm_call_completed" do
    {:ok, session_id} = EventLog.start_session()
    {:ok, event} = EventLog.append(session_id, :agent_started, %{task: "fork test"})

    conn = post_json("/sessions/#{session_id}/fork", %{fork_event_id: event.id})
    assert conn.status == 422
    body = Jason.decode!(conn.resp_body)
    assert body["error"] =~ "llm_call_completed"

    EventLog.end_session(session_id)
  end

  test "POST /sessions/:id/fork creates new session with events up to fork point" do
    {:ok, session_id} = EventLog.start_session()
    {:ok, _} = EventLog.append(session_id, :agent_started, %{task: "fork test"})
    {:ok, llm_event} = EventLog.append(session_id, :llm_call_completed, %{content: "original", tokens_used: 5, latency_ms: 100, model: "test"})
    {:ok, _} = EventLog.append(session_id, :agent_done, %{content: "done"})

    conn = post_json("/sessions/#{session_id}/fork", %{fork_event_id: llm_event.id})
    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["session_id"])
    new_session_id = body["session_id"]

    # Forked session has events up to and including the llm_call_completed
    {:ok, forked_events} = EventLog.read_session_events(new_session_id)
    assert length(forked_events) == 2
    types = Enum.map(forked_events, & &1.type)
    assert types == [:agent_started, :llm_call_completed]
    # agent_done is NOT included
    assert :agent_done not in types

    EventLog.end_session(session_id)
    EventLog.end_session(new_session_id)
  end

  test "POST /sessions/:id/fork injects alt_response into the forked llm_call_completed event" do
    {:ok, session_id} = EventLog.start_session()
    {:ok, _} = EventLog.append(session_id, :agent_started, %{task: "fork override test"})
    {:ok, llm_event} = EventLog.append(session_id, :llm_call_completed, %{content: "original response", tokens_used: 5, latency_ms: 100, model: "test"})

    conn = post_json("/sessions/#{session_id}/fork", %{
      fork_event_id: llm_event.id,
      alt_response: "overridden response"
    })
    assert conn.status == 201
    new_session_id = Jason.decode!(conn.resp_body)["session_id"]

    {:ok, forked_events} = EventLog.read_session_events(new_session_id)
    last = List.last(forked_events)
    assert last.type == :llm_call_completed
    assert last.payload[:content] == "overridden response"

    EventLog.end_session(session_id)
    EventLog.end_session(new_session_id)
  end

  test "POST /sessions/:id/fork without alt_response preserves original content" do
    {:ok, session_id} = EventLog.start_session()
    {:ok, _} = EventLog.append(session_id, :agent_started, %{task: "fork identical test"})
    {:ok, llm_event} = EventLog.append(session_id, :llm_call_completed, %{content: "keep this", tokens_used: 5, latency_ms: 100, model: "test"})

    conn = post_json("/sessions/#{session_id}/fork", %{fork_event_id: llm_event.id})
    assert conn.status == 201
    new_session_id = Jason.decode!(conn.resp_body)["session_id"]

    {:ok, forked_events} = EventLog.read_session_events(new_session_id)
    last = List.last(forked_events)
    assert last.payload[:content] == "keep this"

    EventLog.end_session(session_id)
    EventLog.end_session(new_session_id)
  end
```

- [ ] **Step 2: Run the full sessions test suite**

```bash
mix test test/shem/rest/sessions_test.exs 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 3: Run the full test suite to check for regressions**

```bash
mix test 2>&1 | tail -10
```

Expected: same or more tests passing than before (849+).

- [ ] **Step 4: Commit**

```bash
git add test/shem/rest/sessions_test.exs
git commit -m "feat: POST /api/sessions/:id/fork with tests"
```

---

## Task 4: POST /api/agents — resume_session_id support

**Files:**
- Modify: `lib/shem/rest/handlers/agents.ex`
- Modify: `test/shem/rest/agents_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/shem/rest/agents_test.exs`:

```elixir
  test "POST /agents with resume_session_id resumes that session" do
    # Create a session with an agent_started event so resume can find the task
    {:ok, session_id} = Shem.EventLog.start_session()
    Shem.EventLog.append(session_id, :agent_started, %{task: "resumed task", preset: "general"})
    Shem.EventLog.append(session_id, :llm_call_completed, %{content: "prior response", tokens_used: 5, latency_ms: 100, model: "test"})
    Shem.EventLog.end_session(session_id)

    stub("resumed")
    conn = post_json("/agents", %{resume_session_id: session_id})
    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["agent_id"])
    assert body["session_id"] == session_id

    Shem.Agent.stop(body["agent_id"])
  end
```

- [ ] **Step 2: Run to confirm it fails**

```bash
mix test test/shem/rest/agents_test.exs 2>&1 | grep "resume_session_id" -A 5
```

Expected: test fails — `POST /agents` ignores `resume_session_id` and returns 400 (task missing).

- [ ] **Step 3: Extend the POST /agents handler**

In `lib/shem/rest/handlers/agents.ex`, replace the existing `post "/"` handler with:

```elixir
  post "/" do
    resume_session_id = Map.get(conn.body_params, "resume_session_id")
    preset = Map.get(conn.body_params, "preset", "general")
    task = Map.get(conn.body_params, "task")
    conversational = Map.get(conn.body_params, "conversational", false)

    cond do
      resume_session_id ->
        task_from_session = extract_task_from_session(resume_session_id)
        task_str = task || task_from_session || "Resumed session"

        case Shem.Agent.resume(resume_session_id, task_str) do
          {:ok, agent_id} ->
            send_json(conn, 201, %{agent_id: agent_id, session_id: resume_session_id})

          {:error, reason} ->
            send_json(conn, 500, %{error: inspect(reason)})
        end

      is_nil(task) or task == "" ->
        send_json(conn, 400, %{error: "task is required"})

      true ->
        case Shem.Agent.start_with_preset(preset, task, conversational: conversational) do
          {:ok, agent_id} ->
            {:ok, session_id} = Shem.Agent.session_id(agent_id)
            send_json(conn, 201, %{agent_id: agent_id, session_id: session_id})

          {:error, :not_found} ->
            send_json(conn, 400, %{error: "unknown preset: #{preset}"})

          {:error, reason} ->
            send_json(conn, 500, %{error: inspect(reason)})
        end
    end
  end
```

Also add the private helper at the bottom of the module (before the existing `defp read_done_content`):

```elixir
  defp extract_task_from_session(session_id) do
    case Shem.EventLog.read_session_events(session_id) do
      {:ok, events} ->
        events
        |> Enum.find(&(&1.type == :agent_started))
        |> case do
          nil -> nil
          e -> e.payload[:task]
        end

      _ ->
        nil
    end
  end
```

- [ ] **Step 4: Run the agent tests**

```bash
mix test test/shem/rest/agents_test.exs 2>&1 | tail -20
```

Expected: all agent tests pass including the new resume test.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/rest/handlers/agents.ex test/shem/rest/agents_test.exs
git commit -m "feat: POST /api/agents supports resume_session_id"
```

---

## Task 5: HTTP router — serve timeline.html

**Files:**
- Modify: `lib/shem/http/router.ex`
- Create: `priv/static/timeline.html` (thin shell — full markup added in Task 7)

- [ ] **Step 1: Add GET /timeline route to HTTP router**

In `lib/shem/http/router.ex`, add the `/timeline` route after the `/` route:

```elixir
defmodule Shem.HTTP.Router do
  use Plug.Router

  plug Plug.Static,
    at: "/",
    from: :shem,
    gzip: false,
    only: ~w(alpine.min.js app.js)

  plug :match
  plug :dispatch

  forward "/api", to: Shem.REST.Router
  forward "/mcp", to: Shem.MCP.Router

  get "/" do
    path = Application.app_dir(:shem, "priv/static/index.html")
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, path)
  end

  get "/timeline" do
    path = Application.app_dir(:shem, "priv/static/timeline.html")
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, path)
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end
end
```

- [ ] **Step 2: Create a minimal timeline.html placeholder**

Create `priv/static/timeline.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Shem — Timeline</title>
  <script src="/app.js" defer></script>
  <script src="/alpine.min.js" defer></script>
</head>
<body>
  <p>Timeline coming soon</p>
</body>
</html>
```

- [ ] **Step 3: Verify the route works**

```bash
mix test test/shem/http/router_test.exs 2>&1 | tail -10
```

Expected: existing HTTP router tests still pass.

- [ ] **Step 4: Commit**

```bash
git add lib/shem/http/router.ex priv/static/timeline.html
git commit -m "feat: serve timeline.html at GET /timeline"
```

---

## Task 6: Alpine.data components in app.js

**Files:**
- Modify: `priv/static/app.js`

- [ ] **Step 1: Add the three Alpine.data components to the bottom of app.js**

Append the following to the end of `priv/static/app.js`:

```js
// ── Timeline: Session List ───────────────────────────────────────────────────

Alpine.data('sessionList', () => ({
  sessions: [],
  selectedId: null,
  _pollTimer: null,

  async init() {
    await this.load();
    this._pollTimer = setInterval(() => this.load(), 5000);
  },

  destroy() {
    clearInterval(this._pollTimer);
  },

  async load() {
    try {
      const res = await fetch('/api/sessions');
      if (res.ok) this.sessions = await res.json();
    } catch (_) {}
  },

  select(sessionId) {
    this.selectedId = sessionId;
    window.dispatchEvent(new CustomEvent('session-selected', { detail: { sessionId } }));
  },

  borderColor(s) {
    if (s.session_id === this.selectedId) return '#60a5fa';
    if (s.active) return '#4ade80';
    return 'transparent';
  },

  statusLabel(s) {
    const map = { running: '● LIVE', done: '✓ DONE', error: '✗ ERROR', unknown: '? UNKNOWN' };
    return map[s.status] || s.status.toUpperCase();
  },

  statusColor(status) {
    const map = { running: '#4ade80', done: '#60a5fa', error: '#f87171', unknown: '#666' };
    return map[status] || '#666';
  },

  timeAgo(isoStr) {
    if (!isoStr) return '—';
    const diff = Math.floor((Date.now() - new Date(isoStr)) / 1000);
    if (diff < 60) return `${diff}s ago`;
    if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
    if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
    return `${Math.floor(diff / 86400)}d ago`;
  },

  truncate(str, max) {
    if (!str) return '(no task)';
    return str.length <= max ? str : str.slice(0, max) + '…';
  }
}));

// ── Timeline: Event Timeline ─────────────────────────────────────────────────

Alpine.data('eventTimeline', () => ({
  sessionId: null,
  sessionLabel: '',
  events: [],
  expanded: {},
  loading: false,

  init() {
    window.addEventListener('session-selected', (e) => {
      this.sessionId = e.detail.sessionId;
      this.load();
    });
  },

  async load() {
    if (!this.sessionId) return;
    this.loading = true;
    this.expanded = {};
    try {
      const res = await fetch(`/api/sessions/${this.sessionId}/events`);
      if (res.ok) this.events = await res.json();
    } catch (_) {}
    this.loading = false;
  },

  toggle(id) {
    this.expanded[id] = !this.expanded[id];
    this.expanded = { ...this.expanded };
  },

  isExpanded(id) {
    return !!this.expanded[id];
  },

  openFork(event) {
    window.dispatchEvent(new CustomEvent('fork-requested', {
      detail: { event, sessionId: this.sessionId }
    }));
  },

  dotColor(type) {
    const map = {
      llm_call_completed: '#818cf8',
      llm_call_started:   '#4c4f8f',
      tool_call:          '#f59e0b',
      agent_tool_called:  '#f59e0b',
      agent_tool_result:  '#d97706',
      agent_done:         '#4ade80',
      agent_error:        '#f87171',
      branch_created:     '#60a5fa',
    };
    return map[type] || '#6b7280';
  },

  label(event) {
    const p = event.payload || {};
    switch (event.type) {
      case 'agent_started':        return `Agent started · ${p.preset || ''}`;
      case 'llm_call_started':     return `LLM call → ${p.model || ''}`;
      case 'llm_call_completed': {
        const lat = p.latency_ms ? `${(p.latency_ms / 1000).toFixed(1)}s` : '';
        const tok = p.tokens_used ? `${p.tokens_used} tok` : '';
        return ['LLM call', lat, tok].filter(Boolean).join(' · ');
      }
      case 'tool_call':           return `Tool: ${p.name || p.tool || ''}`;
      case 'agent_tool_called':   return `Tool: ${p.tool || ''} · ${JSON.stringify(p.args || {}).slice(0, 40)}`;
      case 'agent_tool_result':   return `Tool result: ${p.tool || ''}`;
      case 'agent_turn_completed':return `Turn ${p.turn || ''} complete`;
      case 'agent_done':          return 'Done';
      case 'agent_error':         return `Error: ${p.message || p.reason || ''}`;
      case 'branch_created':      return `Branched from ${(p.original_session_id || '').slice(0, 12)}…`;
      default:                    return event.type;
    }
  },

  canFork(type)   { return type === 'llm_call_completed'; },
  canExpand(type) {
    return ['llm_call_completed','tool_call','agent_tool_called','agent_tool_result','agent_done','agent_error'].includes(type)
      || !['agent_started','llm_call_started','agent_turn_completed','branch_created'].includes(type);
  },

  formatTime(iso) {
    if (!iso) return '';
    return new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  },

  prettyJson(obj) {
    try { return JSON.stringify(obj, null, 2); } catch (_) { return String(obj); }
  }
}));

// ── Timeline: Fork Modal ─────────────────────────────────────────────────────

Alpine.data('forkModal', () => ({
  open: false,
  sessionId: null,
  event: null,
  altResponse: '',
  forking: false,
  success: false,
  error: '',

  init() {
    window.addEventListener('fork-requested', (e) => {
      this.sessionId = e.detail.sessionId;
      this.event = e.detail.event;
      this.altResponse = (e.detail.event.payload || {}).content || '';
      this.forking = false;
      this.success = false;
      this.error = '';
      this.open = true;
    });
  },

  close() { this.open = false; },

  async fork() {
    this.forking = true;
    this.error = '';
    try {
      const res = await fetch(`/api/sessions/${this.sessionId}/fork`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ fork_event_id: this.event.id, alt_response: this.altResponse })
      });
      const body = await res.json();
      if (!res.ok) {
        this.error = body.error || 'Fork failed';
        this.forking = false;
        return;
      }
      this.success = true;
      setTimeout(() => { window.location.href = `/?resume=${body.session_id}`; }, 800);
    } catch (_) {
      this.error = 'Network error';
      this.forking = false;
    }
  },

  promptSnippet() {
    const p = (this.event && this.event.payload) || {};
    const prompt = p.prompt || p.messages || '';
    return typeof prompt === 'string' ? prompt.slice(0, 200) : JSON.stringify(prompt).slice(0, 200);
  }
}));
```

- [ ] **Step 2: Verify the app still compiles (no JS syntax errors)**

Start the dev server briefly and check for console errors:

```bash
mix run --no-halt &
sleep 3
curl -s http://localhost:4000/ | grep -c "alpine" && kill %1
```

Expected: returns `1` (alpine script tag present), no crash.

- [ ] **Step 3: Commit**

```bash
git add priv/static/app.js
git commit -m "feat: Alpine.data components sessionList, eventTimeline, forkModal"
```

---

## Task 7: timeline.html full markup

**Files:**
- Modify: `priv/static/timeline.html`

- [ ] **Step 1: Replace the placeholder with the full two-panel layout**

Overwrite `priv/static/timeline.html` with:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Shem — Timeline</title>
  <script src="/app.js" defer></script>
  <script src="/alpine.min.js" defer></script>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      --bg:      #0f0f1a;
      --surface: #1a1a2e;
      --border:  #2a2a4a;
      --accent:  #7c6af7;
      --text:    #e0e0f0;
      --muted:   #666688;
      --green:   #4ade80;
      --red:     #f87171;
      --blue:    #60a5fa;
      --purple:  #818cf8;
      --amber:   #f59e0b;
    }

    html, body {
      height: 100%; background: var(--bg); color: var(--text);
      font-family: 'JetBrains Mono', 'Fira Code', monospace; font-size: 13px;
    }

    .layout { display: flex; height: 100vh; overflow: hidden; }

    /* Sessions panel */
    .sessions-panel {
      width: 280px; min-width: 280px; flex-shrink: 0;
      background: var(--surface); border-right: 1px solid var(--border);
      display: flex; flex-direction: column; overflow: hidden;
    }

    .panel-header {
      padding: 14px 16px; border-bottom: 1px solid var(--border);
      display: flex; align-items: center; justify-content: space-between;
    }

    .panel-title {
      font-size: 11px; letter-spacing: 1.5px; text-transform: uppercase;
      color: var(--muted);
    }

    .nav-link {
      font-size: 11px; color: var(--accent); text-decoration: none;
      letter-spacing: 0.5px;
    }
    .nav-link:hover { text-decoration: underline; }

    .sessions-list { flex: 1; overflow-y: auto; }

    .session-card {
      padding: 10px 14px; border-bottom: 1px solid var(--border);
      border-left: 2px solid transparent; cursor: pointer;
      transition: background 0.1s;
    }
    .session-card:hover { background: rgba(124,106,247,0.07); }

    .session-status {
      font-size: 10px; letter-spacing: 0.5px; margin-bottom: 3px;
    }

    .session-task {
      color: var(--text); margin-bottom: 4px; line-height: 1.3;
    }

    .session-meta { font-size: 10px; color: var(--muted); }

    /* Event timeline panel */
    .timeline-panel {
      flex: 1; display: flex; flex-direction: column; overflow: hidden;
    }

    .timeline-header {
      padding: 14px 20px; border-bottom: 1px solid var(--border);
      font-size: 11px; color: var(--muted); letter-spacing: 1px;
      text-transform: uppercase; flex-shrink: 0;
    }

    .timeline-body {
      flex: 1; overflow-y: auto; padding: 20px;
    }

    .empty-state {
      display: flex; align-items: center; justify-content: center;
      height: 100%; color: var(--muted); font-size: 12px;
    }

    /* Event row */
    .event-row {
      display: flex; gap: 14px; margin-bottom: 4px;
    }

    .event-spine {
      display: flex; flex-direction: column; align-items: center;
      flex-shrink: 0; width: 12px;
    }

    .event-dot {
      width: 10px; height: 10px; border-radius: 50%;
      margin-top: 4px; flex-shrink: 0;
    }

    .event-line {
      width: 1px; flex: 1; background: var(--border); margin-top: 3px;
    }

    .event-body { flex: 1; padding-bottom: 14px; }

    .event-time {
      font-size: 10px; color: var(--muted); margin-bottom: 2px;
    }

    .event-header {
      display: flex; align-items: center; gap: 10px;
      cursor: pointer; user-select: none;
    }

    .event-label { flex: 1; }

    .expand-toggle { color: var(--muted); font-size: 10px; }

    .fork-btn {
      font-size: 10px; padding: 2px 10px;
      background: rgba(124,106,247,0.12); border: 1px solid var(--accent);
      color: var(--accent); border-radius: 3px; cursor: pointer;
      flex-shrink: 0;
    }
    .fork-btn:hover { background: rgba(124,106,247,0.25); }

    .event-detail {
      margin-top: 8px; background: #0d0d18;
      border: 1px solid var(--border); border-radius: 4px; padding: 10px;
      font-size: 11px; line-height: 1.5;
    }

    .detail-label {
      font-size: 10px; letter-spacing: 1px; color: var(--muted);
      text-transform: uppercase; margin-bottom: 4px; margin-top: 8px;
    }
    .detail-label:first-child { margin-top: 0; }

    .detail-value { color: var(--text); white-space: pre-wrap; word-break: break-all; }

    /* Fork modal */
    .modal-backdrop {
      position: fixed; inset: 0; background: rgba(0,0,0,0.7);
      display: flex; align-items: center; justify-content: center;
      z-index: 100;
    }

    .modal-panel {
      background: var(--surface); border: 1px solid var(--border);
      border-radius: 6px; width: 600px; max-width: 95vw;
      max-height: 90vh; overflow-y: auto;
    }

    .modal-header {
      padding: 14px 18px; border-bottom: 1px solid var(--border);
      display: flex; align-items: center; justify-content: space-between;
      font-size: 13px; font-weight: 600; color: var(--text);
    }

    .modal-close {
      background: none; border: none; color: var(--muted);
      cursor: pointer; font-size: 16px; line-height: 1;
    }

    .modal-body { padding: 18px; display: flex; flex-direction: column; gap: 14px; }

    .field-label {
      font-size: 10px; letter-spacing: 1px; text-transform: uppercase;
      color: var(--muted); margin-bottom: 6px;
    }

    .readonly-box {
      background: #0d0d18; border: 1px solid var(--border);
      border-radius: 4px; padding: 8px 10px;
      color: var(--muted); font-size: 11px; max-height: 80px;
      overflow: hidden; line-height: 1.4;
    }

    .edit-area {
      width: 100%; background: #0d0d18; border: 1px solid var(--accent);
      border-radius: 4px; padding: 10px; color: var(--text);
      font-family: inherit; font-size: 12px; resize: vertical;
      min-height: 110px; outline: none; line-height: 1.5;
    }

    .edit-hint { font-size: 10px; color: var(--muted); }

    .modal-actions { display: flex; gap: 10px; }

    .btn-fork {
      flex: 1; padding: 10px; background: rgba(96,165,250,0.15);
      border: 1px solid var(--blue); color: var(--blue);
      border-radius: 4px; cursor: pointer; font-family: inherit;
      font-size: 12px;
    }
    .btn-fork:disabled { opacity: 0.5; cursor: not-allowed; }
    .btn-fork:not(:disabled):hover { background: rgba(96,165,250,0.3); }

    .btn-cancel {
      padding: 10px 16px; background: transparent;
      border: 1px solid var(--border); color: var(--muted);
      border-radius: 4px; cursor: pointer; font-family: inherit; font-size: 12px;
    }

    .alert-success {
      padding: 10px; background: rgba(74,222,128,0.1);
      border: 1px solid var(--green); border-radius: 4px;
      color: var(--green); font-size: 12px;
    }

    .alert-error {
      padding: 10px; background: rgba(248,113,113,0.1);
      border: 1px solid var(--red); border-radius: 4px;
      color: var(--red); font-size: 12px;
    }
  </style>
</head>
<body>
  <div class="layout">

    <!-- Sessions panel -->
    <aside class="sessions-panel" x-data="sessionList">
      <div class="panel-header">
        <span class="panel-title">Sessions</span>
        <a class="nav-link" href="/">← Chat</a>
      </div>

      <div class="sessions-list">
        <template x-if="sessions.length === 0">
          <div style="padding: 20px; color: var(--muted); font-size: 11px;">No sessions found.</div>
        </template>

        <template x-for="s in sessions" :key="s.session_id">
          <div
            class="session-card"
            :style="`border-left-color: ${borderColor(s)}`"
            @click="select(s.session_id)">
            <div class="session-status" :style="`color: ${statusColor(s.status)}`" x-text="statusLabel(s)"></div>
            <div class="session-task" x-text="truncate(s.task, 36)"></div>
            <div class="session-meta">
              <span x-text="s.turn_count"></span>t
              <template x-if="s.preset"> · <span x-text="s.preset"></span></template>
              · <span x-text="timeAgo(s.started_at)"></span>
            </div>
          </div>
        </template>
      </div>
    </aside>

    <!-- Event timeline panel -->
    <main class="timeline-panel" x-data="eventTimeline">
      <div class="timeline-header">
        <template x-if="!sessionId">Event Timeline</template>
        <template x-if="sessionId">
          <span x-text="sessionId.slice(0, 16) + '…'"></span>
        </template>
      </div>

      <div class="timeline-body">
        <template x-if="!sessionId">
          <div class="empty-state">Select a session to view its timeline.</div>
        </template>

        <template x-if="sessionId && loading">
          <div class="empty-state">Loading…</div>
        </template>

        <template x-if="sessionId && !loading && events.length === 0">
          <div class="empty-state">No events in this session.</div>
        </template>

        <template x-for="(event, i) in events" :key="event.id">
          <div class="event-row">
            <div class="event-spine">
              <div class="event-dot" :style="`background: ${dotColor(event.type)}`"></div>
              <template x-if="i < events.length - 1">
                <div class="event-line"></div>
              </template>
            </div>

            <div class="event-body">
              <div class="event-time" x-text="formatTime(event.timestamp)"></div>

              <div class="event-header" @click="canExpand(event.type) && toggle(event.id)">
                <span
                  class="expand-toggle"
                  x-show="canExpand(event.type)"
                  x-text="isExpanded(event.id) ? '▾' : '▸'">
                </span>
                <span
                  class="event-label"
                  :style="`color: ${dotColor(event.type)}`"
                  x-text="label(event)">
                </span>
                <button
                  x-show="canFork(event.type)"
                  class="fork-btn"
                  @click.stop="openFork(event)">
                  Fork
                </button>
              </div>

              <div class="event-detail" x-show="isExpanded(event.id)" x-cloak>
                <template x-if="event.type === 'llm_call_completed'">
                  <div>
                    <div class="detail-label">Prompt</div>
                    <div class="detail-value" x-text="(event.payload.prompt || event.payload.messages || '—')"></div>
                    <div class="detail-label">Response</div>
                    <div class="detail-value" x-text="(event.payload.content || '—')"></div>
                  </div>
                </template>
                <template x-if="event.type !== 'llm_call_completed'">
                  <div>
                    <div class="detail-label">Payload</div>
                    <div class="detail-value" x-text="prettyJson(event.payload)"></div>
                  </div>
                </template>
              </div>
            </div>
          </div>
        </template>
      </div>
    </main>

  </div>

  <!-- Fork modal -->
  <div class="modal-backdrop" x-data="forkModal" x-show="open" x-cloak @click.self="close()">
    <div class="modal-panel" @click.stop>
      <div class="modal-header">
        <span>Fork from this point</span>
        <button class="modal-close" @click="close()">&#x2715;</button>
      </div>

      <div class="modal-body">
        <div>
          <div class="field-label">Forking from</div>
          <div class="readonly-box" x-text="event && event.id"></div>
        </div>

        <div x-show="event && promptSnippet()">
          <div class="field-label">Original prompt</div>
          <div class="readonly-box" x-text="promptSnippet()"></div>
        </div>

        <div>
          <div class="field-label">Response — edit to override, or leave as-is to replay identically</div>
          <textarea class="edit-area" x-model="altResponse"></textarea>
          <div class="edit-hint">Leave unchanged to replay the exact same response from this point.</div>
        </div>

        <div x-show="error" class="alert-error" x-text="error"></div>
        <div x-show="success" class="alert-success">✓ Fork created — opening in chat…</div>

        <div class="modal-actions">
          <button class="btn-fork" :disabled="forking || success" @click="fork()">
            <span x-text="forking ? 'Forking…' : 'Fork from here →'"></span>
          </button>
          <button class="btn-cancel" @click="close()">Cancel</button>
        </div>
      </div>
    </div>
  </div>

</body>
</html>
```

- [ ] **Step 2: Commit**

```bash
git add priv/static/timeline.html
git commit -m "feat: timeline.html two-panel UI with event timeline and fork modal"
```

---

## Task 8: index.html — Timeline nav link + ?resume param handling

**Files:**
- Modify: `priv/static/index.html`

- [ ] **Step 1: Add the Timeline nav link to the sidebar**

In `priv/static/index.html`, find the sidebar block containing the "New Chat" button and add the Timeline link after the `<button class="btn btn-outline" @click="newChat()">` block:

```html
      <a href="/timeline" style="display:block;text-align:center;padding:8px;border:1px solid var(--border);border-radius:6px;color:var(--muted);font-size:12px;text-decoration:none;" onmouseover="this.style.color='var(--accent)'" onmouseout="this.style.color='var(--muted)'">
        Timeline ↗
      </a>
```

- [ ] **Step 2: Handle ?resume on init in app.js**

In `priv/static/app.js`, find the `async init()` method inside the `shem()` function (currently: `async init() { await this._loadPresets(); }`). Replace it with:

```js
    async init() {
      await this._loadPresets();
      const params = new URLSearchParams(window.location.search);
      const resumeId = params.get('resume');
      if (resumeId) {
        await this._resumeSession(resumeId);
        // Clean the URL without reload
        window.history.replaceState({}, '', '/');
      }
    },

    async _resumeSession(sessionId) {
      this.messages.push({ role: 'assistant', content: '', pending: true });
      this.status = 'running';
      try {
        const res = await fetch('/api/agents', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ resume_session_id: sessionId })
        });
        if (!res.ok) {
          this.errorMsg = 'Failed to resume session';
          this.status = 'error';
          this.messages[this.messages.length - 1].pending = false;
          return;
        }
        const data = await res.json();
        this.agentId = data.agent_id;
        this._startShadowPolling();
        await this._openStream(this.agentId);
      } catch (_) {
        this.errorMsg = 'Failed to resume session';
        this.status = 'error';
        this.messages[this.messages.length - 1].pending = false;
      }
    },
```

- [ ] **Step 3: Run the full test suite**

```bash
mix test 2>&1 | tail -10
```

Expected: all tests pass, count ≥ 860 (849 + ~13 new tests from this phase).

- [ ] **Step 4: Commit**

```bash
git add priv/static/index.html priv/static/app.js
git commit -m "feat: Timeline nav link and ?resume session handling in chat UI"
```

---

## Final check

- [ ] **Verify all new files exist**

```bash
ls lib/shem/rest/handlers/sessions.ex priv/static/timeline.html test/shem/rest/sessions_test.exs
```

- [ ] **Run full suite one more time**

```bash
mix test 2>&1 | tail -5
```

Expected: green, no failures.
