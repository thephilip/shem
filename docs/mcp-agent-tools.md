# MCP Agent Tools — Design Spec

## Problem

The current MCP surface (`execute_code`, `graduate_tool`, `list_tools`, `invoke_tool`) requires
the caller to write Elixir. That limits it to Elixir developers or AI clients that can generate
Elixir. Shem's actual value — its agent orchestration system — is completely invisible over MCP.

## Goal

Expose Shem agents over MCP so any MCP client (Claude Code, other AI tools) can spawn agents,
check their progress, and retrieve results — without touching Elixir.

## New Tools

### `spawn_agent`

Starts a Shem agent with a goal and returns an agent ID immediately (non-blocking).

**Input:**
```json
{
  "goal": "Summarise the last 10 git commits in this repo",
  "preset": "default",
  "tools": ["shell", "read_file"]
}
```

**Output:**
```json
{
  "agent_id": "agt_abc123",
  "status": "running"
}
```

`preset` and `tools` are optional. If omitted, the agent uses the default preset with no extra
tools beyond whatever the preset defines.

---

### `agent_status`

Poll an agent by ID. Returns current status and any output accumulated so far.

**Input:**
```json
{ "agent_id": "agt_abc123" }
```

**Output:**
```json
{
  "agent_id": "agt_abc123",
  "status": "running",
  "output": "Fetching commits...\n",
  "events": 4
}
```

`status` is one of: `running`, `waiting`, `done`, `error`.

When `status` is `done` or `error`, `output` contains the final result or error message.

---

### `list_agents`

Returns all active agents with their current status.

**Output:**
```json
{
  "agents": [
    { "agent_id": "agt_abc123", "status": "running", "goal": "Summarise...", "events": 4 },
    { "agent_id": "agt_def456", "status": "done", "goal": "List files...", "events": 12 }
  ]
}
```

---

### `stop_agent`

Sends a stop signal to a running agent.

**Input:**
```json
{ "agent_id": "agt_abc123" }
```

**Output:**
```json
{ "ok": true }
```

## Usage Pattern (Claude Code side)

```
spawn_agent(goal: "...") → agent_id
loop:
  agent_status(agent_id) → check status
  if done/error → break
  sleep a bit, retry
read final output from last agent_status call
```

This is the `dispatching-parallel-agents` pattern: Claude Code spawns multiple agents for
independent subtasks, polls them concurrently, and assembles results.

## What's Needed to Implement

1. **`Shem.MCP.Handlers.SpawnAgent`** — calls `Shem.Agent.start/1` with a goal, returns the
   session_id as agent_id.

2. **`Shem.MCP.Handlers.AgentStatus`** — looks up agent via `Shem.Registry`, reads accumulated
   output from `Shem.EventLog` for that session.

3. **`Shem.MCP.Handlers.ListAgents`** — queries `Shem.AgentSupervisor` for all live agents plus
   recent completed sessions from the event log.

4. **`Shem.MCP.Handlers.StopAgent`** — sends stop to the agent process.

5. Wire all four into `Shem.MCP.Router` dispatch and `builtin_tool_descriptors/0`.

## What's NOT in scope here

- Streaming agent output over SSE (poll is sufficient for now)
- Auth / per-client agent isolation
- Passing arbitrary tool lists to agents at spawn time (preset covers this for now)
