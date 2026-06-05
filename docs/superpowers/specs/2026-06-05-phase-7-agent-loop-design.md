# Phase 7: Agent Loop — Design Spec

**Date:** 2026-06-05
**Status:** Approved

---

## 1. Overview

Phase 7 wires all existing primitives — LLM driver, EventLog, MCP client, Lab sandbox — into a living autonomous agent. A `Shem.Agent` GenServer takes a task, drives a ReAct loop (reason → act → observe), invokes tools, and terminates when the LLM produces a plain-text answer or a circuit breaker fires.

The self-evolving path is not a special mode: it emerges from built-in tools (`write_tool`, `run_code`) that call the Lab graduation pipeline. A tool graduated mid-run appears in the next turn's manifest automatically.

---

## 2. New Modules

All under `lib/shem/agent/`:

### `Shem.Agent`
Public API and config struct.

```elixir
%Shem.Agent.Config{
  task:          String.t(),
  system_prompt: String.t(),
  tools:         [String.t()],   # allowed MCP tool names; [] = all
  model:         atom(),
  max_turns:     pos_integer()
}
```

Functions: `start/1`, `stop/1`, `status/1`. Delegates process lifecycle to `AgentSupervisor`.

### `Shem.Agent.Server`
GenServer. Owns mutable state: config, conversation history, session_id, turn_count, status.

**Status values:** `:idle | :running | :done | :error`

Drives the loop via `handle_info(:run_turn)`. On each turn:
1. Check circuit breakers (max_turns, budget).
2. Delegate to `Turn.step/2`.
3. Handle result: schedule next turn, or halt and record final status.
4. Append EventLog events.

Restart strategy: `:temporary` — a crashed agent does not auto-restart. Partial EventLog session is left open for recovery.

### `Shem.Agent.Turn`
Pure functions. No side effects.

- `step(config, history, tools_manifest)` → calls `Shem.LLM.complete/1` → parses response → returns:
  - `{:tool_calls, [%{tool: name, args: map}], raw_content}`
  - `{:done, answer}`
  - `{:error, reason}`
- `build_prompt(system_prompt, tools_manifest, history)` → `String.t()`
- `parse_response(content)` → extracts JSON tool call blocks from prose; tolerant of surrounding text.

The `tools_manifest` is built by the Server before each call to `Turn.step` — querying `Lab.Registry`, `MCP.Client`, and built-ins fresh on every turn. This keeps `Turn` side-effect free while ensuring newly graduated tools are visible.

### `Shem.Agent.ToolDispatch`
Routes parsed tool calls to their handler. Always returns `{:ok, result_string} | {:error, reason_string}` — both are appended to history as observations.

Dispatch order:
1. **Built-ins** — checked first by tool name.
2. **Graduated Lab tools** — `Shem.Lab.Registry.lookup/1`.
3. **MCP tools** — `Shem.MCP.Client.call/3`.

---

## 3. Built-in Tools

### `write_tool`
Args: `%{name, description, source, test_source}`

Calls `Shem.Lab.GraduationGate.graduate/3`. On success: `"graduated: <name>"`. On failure: compiler or test error string. The LLM sees failures as observations and rewrites on the next turn.

### `run_code`
Args: `%{source, timeout_ms}`

Calls `Shem.Lab.Executor.run/2`. Returns stdout or exit reason. Used to prototype behaviour before committing to graduation.

### `list_tools`
Args: none.

Returns the current tool manifest as a formatted string. Rebuilt fresh each call from MCP + Lab.Registry + built-ins.

---

## 4. Data Flow (one turn)

```
Server.handle_info(:run_turn)
  │
  ├─ turn_count >= max_turns? → {:stop, :max_turns_reached}
  ├─ BudgetServer.remaining() == 0? → {:stop, :budget_exhausted}
  │
  ├─ build tools_manifest (Lab.Registry + MCP.Client + built-ins)
  ├─ Turn.step(config, history, tools_manifest)
  │     ├─ build_prompt(system_prompt, tools_manifest, history)
  │     ├─ Shem.LLM.complete(%Request{prompt, model, session_id})
  │     └─ parse_response(content)
  │           ├─ found tool call → {:tool_calls, calls, raw}
  │           └─ no tool call   → {:done, content}
  │
  ├─ on {:tool_calls, calls, raw}:
  │     ├─ append %{role: :assistant, content: raw} to history
  │     ├─ ToolDispatch.execute/2 for each call → result string
  │     ├─ append %{role: :tool, content: result} to history
  │     └─ send_self(:run_turn)
  │
  └─ on {:done, answer}:
        ├─ append %{role: :assistant, content: answer} to history
        └─ status → :done
```

### History format
Plain list of `%{role: :system | :user | :assistant | :tool, content: String.t()}`. The prompt builder flattens this into the model's expected text format (system block + alternating turns).

### Tool manifest
Rebuilt at the start of each turn by merging:
- `Shem.MCP.Client` tools (filtered by `config.tools` allowlist; empty list = all)
- `Shem.Lab.Registry.all/0` graduated tools
- Built-in tools

This means a tool graduated mid-run is available in the very next turn with no extra wiring.

---

## 5. EventLog Events

All events are appended to the session opened at agent startup. The LLM middleware `EventLogger` appends its own `llm_call_*` events to the same session, giving a complete single-session trace.

| Event type              | Payload                                      |
|-------------------------|----------------------------------------------|
| `:agent_started`        | `%{task, model, max_turns}`                  |
| `:agent_turn_started`   | `%{turn: n}`                                 |
| `:agent_tool_called`    | `%{tool: name, args: map}`                   |
| `:agent_tool_result`    | `%{tool: name, result: string}`              |
| `:agent_budget_warning` | `%{remaining: n}`                            |
| `:agent_turn_completed` | `%{turn: n, outcome: :tool_calls \| :done}`  |
| `:agent_done`           | `%{reason: :answer \| :max_turns \| :budget_exhausted}` |
| `:agent_error`          | `%{reason: term}`                            |

---

## 6. Error Handling & Circuit Breakers

**Per-tool errors** — `ToolDispatch` always returns a string. Both success and failure are observations. A failed tool call never aborts a turn — the agent can retry, correct, or abandon.

**LLM errors** — `{:error, reason}` from `Shem.LLM.complete/1` transitions the Server to `:error` and stops. No silent retry.

**Circuit breakers** — checked before each turn:
- `turn_count >= max_turns` → `:done`, reason `:max_turns_reached`
- `BudgetServer.remaining() == 0` → `:done`, reason `:budget_exhausted`
- Soft budget warning from `BudgetCheck` middleware → `:agent_budget_warning` event, loop continues

**Crash isolation** — `:temporary` restart under `AgentSupervisor`. Crashed agents do not cascade.

**Timeouts** — `Lab.Executor` and `MCP.Client` already enforce their own timeouts and return `{:error, :timeout}`, which surfaces as an observation string.

---

## 7. `AgentSupervisor` Update

Replace the current bare `Agent` child spec with a `Shem.Agent.Server` child spec. `start_agent/1` accepts a `%Agent.Config{}` and starts a supervised `Agent.Server`.

---

## 8. Testing

### `Shem.Agent.Turn` (pure unit tests)
- No tool call in response → `{:done, answer}`
- Single JSON tool call embedded in prose → `{:tool_calls, [%{tool, args}], raw}`
- Multiple tool calls → all extracted
- Malformed/partial JSON → graceful fallback to `:done`
- Empty response → `:done`

### `Shem.Agent.ToolDispatch` (unit tests)
- Built-in `write_tool` success and failure paths (tmp Lab dir + FakeStore)
- Built-in `run_code` success and timeout
- MCP dispatch via `StubTransport` or process dict override
- Unknown tool → `{:error, "unknown tool: <name>"}`

### `Shem.Agent.Server` (integration tests via `StubTransport`)
- Two-turn run: turn 1 calls `write_tool`, turn 2 is `:done`. Assert EventLog events; assert tool in `Lab.Registry`.
- Self-correction: turns 1 and 2 call `write_tool` with bad source (compiler error as observation each time), turn 3 calls `write_tool` with corrected source and succeeds. Assert tool in `Lab.Registry` after run.
- Max-turns circuit breaker fires before LLM call on turn N+1.
- Budget-exhausted circuit breaker.
- LLM transport error → agent status `:error`.

---

## 9. Self-Evolution Path (in practice)

1. Agent receives a task requiring an unavailable capability.
2. Calls `run_code` to prototype and verify logic.
3. Calls `write_tool` with source + tests.
4. `GraduationGate` compiles and tests — failure becomes an observation; agent rewrites.
5. On success, tool appears in next turn's manifest.
6. Agent calls the newly graduated tool to complete its task.

The system prompt encodes when the agent should reach for `write_tool` vs. existing MCP tools, and carries the agent's personality (e.g. "FP Artisan" style constraints). Each agent started with a distinct task carries its own `system_prompt` — the self-evolving identity of the framework lives here.

---

## 10. Out of Scope (Phase 8+)

- Streaming LLM responses
- Multi-agent coordination / trust-weighted consensus
- BEAM node distribution / agent migration
- Named agent presets from app config
- Timeline Mode TUI view for agent runs
- Red-team adversarial agents
