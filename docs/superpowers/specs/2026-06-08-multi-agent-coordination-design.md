# Multi-Agent Coordination

**Date:** 2026-06-08  
**Status:** Approved for implementation

## Overview

Agents gain a `spawn_agent` built-in tool that delegates a sub-task to a new agent and returns its final answer. The parent blocks until the sub-agent completes — a natural fit for the ReAct loop, which processes one tool result at a time before reasoning further. The sub-agent runs concurrently in its own GenServer process on BEAM; the parent is suspended but does not block the scheduler or other agents.

This is intentionally blocking (not parallel dispatch). Parallel sub-agent coordination can be layered on top once this foundation is proven.

## Known Design Decision: Blocking + Timeout Risk

`spawn_agent` blocks the parent agent's `handle_info(:run_turn, ...)` for the duration of the sub-agent's run. This is safe in BEAM terms but means parent wall-clock time grows with sub-agent complexity. If a parent agent appears to hang or timeout for no obvious reason, check `spawn_agent_timeout_ms` config and the sub-agent's EventLog session first. See also: nested delegation compounds latency.

## Architecture & Components

### New public function

**`Agent.await_result/2`** — new function on `Shem.Agent`. Awaits sub-agent completion, reads the EventLog to extract the `:agent_done` event content, and returns it as a string. Keeps all EventLog access inside the `Agent` module.

```elixir
@spec await_result(String.t(), timeout()) :: {:ok, String.t()} | {:error, term()}
```

Returns:
- `{:ok, answer}` — sub-agent completed, answer is the final `:assistant` content
- `{:error, :sub_agent_failed}` — sub-agent finished with `:error` status
- `{:error, :timeout}` — sub-agent did not complete within `timeout` (propagated from `Agent.await/2`, which already catches the GenServer.call exit)
- `{:error, :no_result}` — sub-agent finished but no `:agent_done` event found (defensive)

### Modified module

**`Shem.Agent.ToolDispatch`** — one new entry in `@builtins`, one new `dispatch_builtin` clause. No other changes to any existing module (`Agent.Server`, `Turn`, `AgentSupervisor` are untouched).

## Tool Interface

```
spawn_agent – args: task (string, required), preset (string, optional, default "general")
              result: "<sub-agent's final answer>"
                    | "sub-agent failed: <reason>"
                    | "spawn_agent depth limit reached (N)"
```

JSON schema:
```json
{
  "type": "object",
  "properties": {
    "task":   {"type": "string"},
    "preset": {"type": "string"}
  },
  "required": ["task"]
}
```

Description surfaced to agents: `"Delegate a task to a sub-agent. Specify the task and optionally a preset name (default: general). Returns the sub-agent's final answer."`

If `preset` is omitted it defaults to `"general"`. If the named preset doesn't exist, `start_with_preset/2` returns `{:error, :not_found}` and the tool result is `"sub-agent failed: not_found"` — the parent can react and retry with a different preset.

## Depth Guard

`dispatch_builtin("spawn_agent", ...)` reads `Process.get(:spawn_agent_depth, 0)` and compares against `Application.get_env(:shem, :spawn_agent_max_depth, 3)`. If at or above the limit, returns `{:error, "spawn_agent depth limit reached (N)"}` before starting any process.

On entry: `Process.put(:spawn_agent_depth, depth + 1)`.  
On exit (success or error): `Process.put(:spawn_agent_depth, depth)` — depth is always restored.

Using the process dictionary is correct here: each agent runs in its own GenServer process, so depth is naturally scoped per agent chain with no shared state.

## Config

```elixir
# dev default (config/config.exs or runtime.exs)
config :shem, spawn_agent_timeout_ms: 300_000   # 5 minutes
config :shem, spawn_agent_max_depth: 3

# test.exs
config :shem, spawn_agent_timeout_ms: 5_000
config :shem, spawn_agent_max_depth: 2
```

## Error Handling

| Failure | Source | Tool result |
|---------|--------|-------------|
| Depth exceeded | depth guard | `"spawn_agent depth limit reached (N)"` |
| Unknown preset | `start_with_preset/2` → `{:error, :not_found}` | `"sub-agent failed: not_found"` |
| Sub-agent max_turns / budget / runtime error | `await_result/2` → `{:error, :sub_agent_failed}` | `"sub-agent failed: sub_agent_failed"` |
| Timeout | `await_result/2` → `{:error, :timeout}` | `"sub-agent failed: timeout"` |

No crash propagates to the parent. All failures are tool results the parent can reason about.

## Testing

**Config:** `test.exs` adds `spawn_agent_timeout_ms: 5_000` and `spawn_agent_max_depth: 2`.

**`Agent.await_result/2` unit tests:**
- Happy path: start agent with StubTransport queued to return a final answer, call `await_result/2`, assert `{:ok, "...answer..."}`.
- Error path: StubTransport queued to produce an agent error, assert `{:error, :sub_agent_failed}`.

**`ToolDispatch` integration tests via `execute/2`:**
- Happy path: queue StubTransport responses for both parent and sub-agent turns; call `execute(%{name: "spawn_agent", args: %{"task" => "...", "preset" => "general"}}, manifest)`; assert `{:ok, answer}`.
- Unknown preset: assert tool result contains `"sub-agent failed"`.
- Depth guard: `Process.put(:spawn_agent_depth, 2)` before calling `execute/2`; assert `{:error, "spawn_agent depth limit reached (2)"}` with no agent started.

## What This Is Not

- **Not parallel dispatch.** One `spawn_agent` call = one sub-agent = parent blocks until done. Parallel fan-out is a future phase.
- **Not bidirectional.** Sub-agents cannot message the parent; they only return a final answer.
- **Not persistent delegation.** Sub-agent sessions exist in the EventLog but are independent; there is no parent/child linkage in the EventLog schema.
