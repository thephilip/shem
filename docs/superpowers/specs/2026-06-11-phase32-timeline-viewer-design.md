# Phase 32 — Timeline Viewer

## Overview

A web-based timeline viewer that makes the Shem event log navigable and forkable. This is Shem's moat made visible: every LLM call, tool invocation, and agent turn is inspectable, and any LLM response can be branched from with an override. No Python framework can build this without a replayable, structured event store.

**Served at:** `http://localhost:4000/timeline`

---

## Scope

### Phase 32 (this spec)
- Sessions list with live/historical status
- Per-session event timeline — vertical, chronological, colour-coded by event type
- Expandable event cards — prompt, response, tool args/result, token count, latency
- Fork button on LLM call events — modal with editable response override, creates a branched session and navigates to the chat UI to continue

### Phase 32b (deferred)
- Live side-by-side comparison — fork opens a split panel instead of navigating away; both sessions stream live
- Diff view — `LLM.Branch.compare/1` powers a side-by-side session comparison launched from the sessions list
- Share link — `GET /api/sessions/:id/share` generates a read-only token; `/s/:token` serves a stripped timeline view
- TUI event-detail upgrade — expand the History browser detail panel to show individual events (type + truncated payload) instead of the current `t1:shell · t2:done` summary line

---

## Architecture

### Approach: Separate page + shared `app.js`

`timeline.html` is a standalone page, not a tab inside `index.html`. Both pages share `app.js` for common logic (fetch helpers, SSE, Alpine component registration). Each page is thin HTML; `app.js` carries the state.

**Why not a tab inside `index.html`:** `index.html` is already a full chat application. Embedding a timeline viewer inside it couples two distinct mental modes and produces a God file. Separate pages evolve independently.

**Why not React:** No build step in an OTP release. Alpine.js with `Alpine.data()` named components in `app.js` gives us proper component structure without webpack/vite.

### New files
- `priv/static/timeline.html` — thin HTML shell; imports `alpine.min.js` + `app.js`
- `lib/shem/rest/handlers/sessions.ex` — REST handler for sessions and fork

### Modified files
- `priv/static/app.js` — gains `Alpine.data('sessionList', ...)`, `Alpine.data('eventTimeline', ...)`, `Alpine.data('forkModal', ...)`, and shared fetch/SSE helpers extracted from inline `index.html` script blocks
- `lib/shem/rest/router.ex` — adds `forward "/sessions", to: Shem.REST.Handlers.Sessions`
- `lib/shem/http/router.ex` — adds `GET /timeline` → serves `timeline.html`

---

## REST API

### `GET /api/sessions`

Returns all sessions sorted newest-first. Merges active sessions from `EventLog.list_sessions/0` (filtering those without `ended_at`) with historical sessions from `HistoryScanner.scan/0`.

**Response:**
```json
[
  {
    "session_id": "abc123",
    "task": "Refactor auth middleware",
    "started_at": "2026-06-11T10:42:00Z",
    "status": "running",
    "turn_count": 6,
    "active": true
  },
  {
    "session_id": "def456",
    "task": "Write unit tests for Lab executor",
    "started_at": "2026-06-11T09:30:00Z",
    "status": "done",
    "turn_count": 4,
    "active": false
  }
]
```

Status values: `"running"` | `"done"` | `"error"` | `"unknown"`

### `GET /api/sessions/:id/events`

Returns all events for a session, formatted for display. Calls `EventLog.read_session_events/1` for historical sessions or `EventLog.events/1` for active ones.

**Response:**
```json
[
  {
    "id": "evt_3F9A2B1C",
    "type": "llm_call_completed",
    "timestamp": "2026-06-11T10:42:02Z",
    "payload": {
      "content": "I'll start by examining...",
      "prompt": "Write ExUnit tests for...",
      "tokens_used": 412,
      "latency_ms": 1312,
      "model": "qwen3-27b"
    },
    "parent_id": "evt_1A2B3C4D"
  }
]
```

Returns `404` if session not found.

### `POST /api/sessions/:id/fork`

Creates a new session branched from the given event. Copies events from the original session up to and including `fork_event_id`, then optionally appends a synthetic `llm_call_completed` event with `alt_response` as its content. Returns the new session ID.

**Request body:**
```json
{
  "fork_event_id": "evt_3F9A2B1C",
  "alt_response": "Optional override text. Omit to replay identically."
}
```

**Response `201`:**
```json
{ "session_id": "ghi789" }
```

**Error responses:**
- `404` — original session not found
- `422` — `fork_event_id` not found in session, or event is not `llm_call_completed`

**Fork mechanics:** The handler reads events from the original session, slices up to and including `fork_event_id`, writes them to a new EventLog session via `EventLog.append/3`, and if `alt_response` is present, appends a synthetic `llm_call_completed` event with the override content. This is a lightweight EventLog-copy operation — it does not use `LLM.Branch.branch_at/4`, which is designed for programmatic replay with a running function. The new session is immediately resumable via `Agent.resume/2`.

---

## UI Layout

### `timeline.html` — Two-panel layout

```
┌──────────────────────────────────────────────────────────┐
│  SESSIONS                │  SESSION DETAIL               │
│  ──────────────────────  │  ───────────────────────────  │
│  ● LIVE                  │  WRITE UNIT TESTS · 4T · DONE │
│  Refactor auth…          │                               │
│  6t · coder · 2m ago     │  ○ 10:42:01  Agent started    │
│                          │  ● 10:42:02  LLM call  [Fork] │
│  ● DONE  ← selected      │    ▾ prompt + response        │
│  Write unit tests…       │  ● 10:42:03  Tool: read_file  │
│  4t · coder · 1h ago     │  ● 10:42:05  LLM call  [Fork] │
│                          │  ○ 10:42:08  ✓ Done           │
│  ○ DONE                  │                               │
│  Summarise paper…        │                               │
└──────────────────────────────────────────────────────────┘
```

- Left panel (fixed 280px): scrollable session list, newest-first. Coloured left border: green=live, blue=selected, none=past. Status badge, task name (truncated), turn count + preset + time-ago.
- Right panel (flex): event timeline for the selected session. Vertical timeline with connector line. Clicking a session in the left panel loads its events via `GET /api/sessions/:id/events`.

### Alpine components (registered in `app.js`)

**`Alpine.data('sessionList')`**
- `sessions: []`, `selectedId: null`
- `init()` — fetches `/api/sessions`, polls every 5s for active session updates
- `select(session_id)` — sets `selectedId`, dispatches `session-selected` custom event

**`Alpine.data('eventTimeline')`**
- `events: []`, `expandedIds: Set`, `loading: false`
- Listens for `session-selected` event, fetches `/api/sessions/:id/events`
- `toggle(event_id)` — expands/collapses an event card
- `openFork(event)` — dispatches `fork-requested` with event data

**`Alpine.data('forkModal')`**
- `open: false`, `event: null`, `altResponse: ''`, `forking: false`
- Listens for `fork-requested`, pre-fills `altResponse` from `event.payload.content`
- `fork()` — POSTs to `/api/sessions/:id/fork`, on success navigates to `index.html?resume=<new_session_id>`

Components communicate via browser custom events (`dispatchEvent` / `addEventListener`) rather than shared global state, keeping them independently testable.

---

## Event Display

| Event type | Dot colour | Label | Expandable | Fork |
|---|---|---|---|---|
| `agent_started` | grey | `Agent started · {preset}` | no | no |
| `llm_call_started` | purple (dim) | `LLM call → {model}` | no | no |
| `llm_call_completed` | purple | `LLM call · {latency}s · {tokens} tok` | yes — prompt + response | **yes** |
| `tool_call` | amber | `Tool: {name} · {truncated args}` | yes — full args + result | no |
| `agent_turn_completed` | grey | `Turn {n} complete` | no | no |
| `agent_done` | green | `Done` | yes — final content | no |
| `agent_error` | red | `Error: {message}` | yes — full payload | no |
| `branch_created` | blue | `Branched from {original_session_id}` | no | no |
| *(any other)* | grey | `{type}` | yes — raw JSON payload | no |

Fork is only offered on `llm_call_completed` events. These are the meaningful branch points: they contain the editable LLM response and are what `LLM.Branch` operates on.

---

## Fork Flow (end-to-end)

1. User clicks **Fork** on an `llm_call_completed` event card
2. `forkModal` opens; `altResponse` textarea pre-filled with `event.payload.content`
3. User edits the response (or leaves it unchanged to replay identically)
4. User clicks **Fork from here →**
5. `forkModal.fork()` POSTs `{fork_event_id, alt_response}` to `/api/sessions/:id/fork`
6. Handler copies events, injects override if present, returns `{session_id: "new_id"}`
7. UI shows brief success state ("Fork created — opening in chat…"), then navigates to `index.html?resume=new_id`
8. `index.html` detects `?resume` query param on init, calls `POST /api/agents` with `resume_session_id: new_id` to continue the forked session conversationally. **`resume_session_id` is a new parameter** — `Shem.REST.Handlers.Agents` must be extended to call `Agent.resume/2` when this field is present, rather than starting a fresh agent.

---

## Navigation

- `index.html` gains a **Timeline** link in its nav/header → `href="/timeline"`
- `timeline.html` has a **← Chat** link → `href="/"`
- `index.html` on init: if `?resume=<id>` is in the query string, auto-resume that session

---

## Testing

**`Shem.REST.Handlers.SessionsTest`**
- `GET /api/sessions` — returns merged active + historical list, sorted newest-first; active sessions have `"active": true`
- `GET /api/sessions/:id/events` — returns formatted event list; `404` for unknown session
- `POST /api/sessions/:id/fork` — copies events up to fork point; injected `alt_response` appears as final `llm_call_completed` event; `422` for non-existent or non-LLM event id
- Fork with no `alt_response` — copied session ends with the original `llm_call_completed` event unchanged

No browser/JS tests. Alpine component correctness is validated by running the app.

---

## Key decisions

- **Separate page, not a tab:** keeps the chat app and timeline viewer independently evolvable; prevents `index.html` becoming a God file
- **Alpine.data() components, not inline x-data:** named components in `app.js` give reusability and testability without a build step
- **EventLog-copy fork, not LLM.Branch.branch_at:** `branch_at/4` requires a running function; the web UI fork needs a persistent session that the user can resume conversationally. Copy-then-resume is the right primitive here.
- **Fork on llm_call_completed only:** the other event types don't contain a meaningful response to override; tool calls, agent lifecycle events, and turn markers aren't branch points
- **5s polling for session list:** SSE would be cleaner for live updates but adds server-side complexity for a list that changes infrequently. Polling is fine here.
