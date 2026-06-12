# Phase 36 — MCP Agent Tools

## Why this phase exists

Hermes has no MCP surface. Shem does — but right now it only exposes low-level Elixir
primitives (`execute_code`, `graduate_tool`) that require the caller to write Elixir code.
Shem's actual value — the agent orchestration system — is invisible over MCP.

This phase exposes Shem's agents over MCP so any MCP client (Claude Code, other AI tools,
scripts) can spawn agents, check their progress, and retrieve results without touching Elixir.
This is Shem's clearest differentiator: a self-improving agent platform that is also a
first-class MCP backend.

The detailed design is in `docs/mcp-agent-tools.md`. This spec adds implementation guidance.

---

## New MCP tools

### `spawn_agent`

Starts a Shem agent with a goal. Returns an agent ID immediately (non-blocking).

**Input:** `goal` (required), `preset` (optional, default `"general"`), `tools` (optional)
**Output:** `{ agent_id, status: "running" }`

Implementation: call `Shem.Agent.start/1` with a `Config` built from the inputs. Return the
`session_id` as `agent_id`.

---

### `agent_status`

Poll an agent by ID. Returns status and accumulated output.

**Input:** `agent_id`
**Output:** `{ agent_id, status, output, events }`

`status` is one of: `running`, `waiting`, `done`, `error`.

Implementation: look up agent in `Shem.Registry`. If alive, read status via `Agent.status/1`
and fetch events from `EventLog.read_session_events/1`, extracting assistant content. If not
in registry, check EventLog for a completed session (tombstone pattern).

---

### `list_agents`

Returns all active agents with current status.

**Output:** `{ agents: [{ agent_id, status, goal, events }] }`

Implementation: `Horde.DynamicSupervisor.which_children(Shem.AgentSupervisor)` for live
agents; join with recent EventLog sessions for completed ones.

---

### `stop_agent`

Send a stop signal to a running agent.

**Input:** `agent_id`
**Output:** `{ ok: true }`

Implementation: `Shem.Agent.stop/1`.

---

## Implementation checklist

1. `lib/shem/mcp/handlers/spawn_agent.ex` — `call/1`, builds `Agent.Config`, calls `Agent.start/1`
2. `lib/shem/mcp/handlers/agent_status.ex` — registry lookup + EventLog read
3. `lib/shem/mcp/handlers/list_agents.ex` — supervisor children + recent sessions
4. `lib/shem/mcp/handlers/stop_agent.ex` — `Agent.stop/1` wrapper
5. `lib/shem/mcp/router.ex` — add 4 dispatch clauses to `dispatch_method/2` and 4 entries to `builtin_tool_descriptors/0`

---

## Usage pattern (Claude Code side)

```
spawn_agent(goal: "summarise the last 10 git commits") → { agent_id: "abc123" }

loop:
  agent_status("abc123") → { status: "running", output: "..." }
  if status == "done" → break

final output is in last agent_status response
```

This enables the `dispatching-parallel-agents` pattern: Claude Code spawns multiple Shem
agents for independent subtasks and polls them concurrently.

---

## What is NOT in scope

- Streaming agent output over SSE (polling is sufficient for now)
- Auth / per-client agent isolation
- Passing arbitrary tool lists at spawn time (preset covers this)
- Exposing the EventLog or Trust.Store over MCP (future phase)

---

## Success criteria

- `claude mcp list` shows `shem: ✔ Connected`  *(already done as of v0.1.8)*
- Claude Code can call `spawn_agent`, get an `agent_id`, poll `agent_status`, and read the
  final output — all without writing Elixir
- A parallel dispatch test: two agents spawned simultaneously both complete and return results
