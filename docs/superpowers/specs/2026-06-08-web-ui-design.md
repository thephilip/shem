# Web UI

**Date:** 2026-06-08  
**Status:** Approved for implementation

## Overview

A minimal browser-based UI for starting agents and watching them work. The full REST API and SSE streaming endpoint already exist (Phase 18 + 22); this phase adds static frontend files and a small routing adjustment. No build step, no npm, no external requests.

## Design Rationale

Alpine.js is chosen over vanilla JS because its declarative `state → view` model mirrors the functional, composable thinking Shem applies in Elixir. Imperative DOM manipulation (querySelector, innerHTML, addEventListener) is the opposite of what we value. Alpine's `x-data`/`x-bind`/`x-on` directives are readable, composable, and stateless-by-default. The library (~15kb) is vendored into `priv/static/` — no CDN dependency, fully local-first.

The split-panel layout is chosen over alternatives because it scales naturally to a dashboard as more features arrive (Phase 25 multi-agent list, memory browser, etc.). Left panel = controls/nav; right panel = content. That boundary stays stable across future extensions.

## Architecture & Components

### New files

| Path | Responsibility |
|------|----------------|
| `priv/static/alpine.min.js` | Alpine.js v3, vendored — download once, commit |
| `priv/static/index.html` | Single HTML page, loads Alpine and `app.js`, defines split-panel layout |
| `priv/static/app.js` | Alpine component definition — all reactive state and API calls |

### Modified files

| Path | Change |
|------|--------|
| `lib/shem/http/router.ex` | Add `Plug.Static` for `priv/static/`; move MCP from `/` to `/mcp` |

No changes to REST handlers, `Agent.Server`, `Turn`, or any other module.

## Routing Change

Current `Shem.HTTP.Router`:
```elixir
forward "/api", to: Shem.REST.Router
forward "/",    to: Shem.MCP.Router
```

After:
```elixir
plug Plug.Static, at: "/", from: :shem, gzip: false, only: ~w(alpine.min.js app.js)
forward "/api",  to: Shem.REST.Router
forward "/mcp",  to: Shem.MCP.Router
# Fallback: GET / serves index.html
match "/", via: :get, do: send_file(conn, 200, Application.app_dir(:shem, "priv/static/index.html"))
```

MCP HTTP clients must update their endpoint from `http://host:4000/` to `http://host:4000/mcp`. The MCP stdio client (`Shem.MCP.Client`) is unaffected — it communicates via BEAM Ports, not HTTP.

## Alpine Component State

```js
{
  preset: "general",       // selected preset name
  presets: [],             // populated from GET /api/presets on mount
  task: "",                // task input text
  status: "idle",          // idle | running | done | error
  output: "",              // accumulated SSE token stream
  agentId: null,           // agent_id from POST /api/agents response
  eventSource: null        // active EventSource, null when idle
}
```

## Interaction Flow

1. **Mount** — `GET /api/presets` populates the preset dropdown. Status: `idle`.
2. **Run** — user selects preset, enters task, clicks Run.
   - `POST /api/agents {preset, task}` → `{agent_id, session_id}`
   - Opens `EventSource` on `GET /api/agents/:id/stream`
   - Status: `running`
3. **Streaming** — each SSE `chunk` event (`{type:"chunk", content:"..."}`) appends to `output`. Right panel auto-scrolls via `x-effect`.
4. **Done** — SSE `done` event (`{type:"done", status:"done"}`) closes `EventSource`. Status: `done`.
5. **Stop** — `DELETE /api/agents/:id`, close `EventSource`. Status: `idle`.
6. **Reset** — clears `output`, `task`, `agentId`. Status: `idle`. Form ready for next run.

## UI Structure

```
┌─────────────────────────────────────────────────────────────┐
│  ░ shem                                          [dark bg]  │
├──────────────────┬──────────────────────────────────────────┤
│  PRESET          │  OUTPUT                                  │
│  [general ▾]     │                                          │
│                  │  Analysing the codebase...               │
│  TASK            │  Found 3 files to consider...            │
│  [             ] │  ▌                                       │
│  [             ] │                                          │
│  [             ] │                                          │
│                  │                                          │
│  [Run Agent]     │                                          │
│  [Stop     ]     │                                          │
└──────────────────┴──────────────────────────────────────────┘
```

Left panel (≈30% width): preset dropdown, task textarea, Run/Stop buttons. Stop button visible only when `status === "running"`. Run button disabled when `status === "running"` or task is empty.

Right panel (≈70% width): shows placeholder text when `idle`, streams tokens when `running`, displays full output when `done` or `error`. Error state shown in a distinct colour.

## Error Handling

| Failure | Detection | UI response |
|---------|-----------|-------------|
| `POST /api/agents` network/4xx/5xx | `fetch` catch / non-2xx response | Status → `error`, message in right panel |
| Unknown preset | REST returns 400 | Status → `error`, "unknown preset: X" in right panel |
| SSE disconnect while running | `EventSource.onerror` | Status → `error`, "connection lost" in right panel |
| Agent server-side error | SSE `done` event with `status:"error"` | Status → `error` |
| Stop while already finished | `DELETE` returns 404 | Ignore 404, close EventSource, status → `idle` |

In all error states, output accumulated so far is preserved — the user can read what the agent produced before the failure.

## Testing

- No new ExUnit tests for the static files themselves (Alpine behaviour, `Plug.Static` serving).
- One new test in `test/shem/http_router_test.exs`: `GET /mcp` forwards to MCP router; `GET /` returns 200 with `text/html` content-type.
- All REST API endpoints are already tested in existing handler tests.
- Manual browser verification: start agent via UI, watch SSE stream tokens, verify done state and reset.

## What This Is Not

- **Not a full dashboard.** No agent list, no memory browser, no trust/routes display — those are future extensions enabled by the split-panel foundation.
- **Not server-rendered.** No Phoenix LiveView, no Elixir-generated HTML. Static files only.
- **Not authenticated.** No login, no session management. Shem is local-first; the UI is assumed to be on localhost.
