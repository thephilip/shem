# Phase 6a: Replay & LLM Call Mocking Design

**Date:** 2026-06-04
**Status:** Approved
**Scope:** Deterministic replay of agent sessions with recorded LLM responses — the foundation for golden session regression testing.

---

## 1. Context and Goals

Phase 5 shipped a middleware pipeline that records every LLM call in the event log. Phase 6a builds on that foundation to make those recordings useful: given any past session, re-run agent code against the recorded responses instead of the live model. No API tokens. No non-determinism.

The primary use case is **golden session regression testing**: record a real session that produced correct behavior, commit its session ID to your test suite, and replay it forever as a zero-cost assertion that agent behavior hasn't changed. This is "git bisect for agents" — a capability no Python-based framework can offer because they lack the event log foundation.

Phase 6a is intentionally scoped to replay only. Timeline forking (branching from a point and running live) is Phase 6b.

**What Phase 6a adds:**
- EventLogger patch to record `prompt` and `content` in LLM call events
- `Shem.LLM.ReplayTransport` — terminal middleware serving recorded responses
- `Shem.LLM.Replay` — `with_replay/2` coordinator and `diff/2` utility
- Divergence and exhaustion as first-class recorded events (permissive model)

---

## 2. Architecture

Phase 6a follows the established middleware pattern: one new terminal middleware (`ReplayTransport`) and one coordinator module (`Shem.LLM.Replay`). The `complete/1` API is unchanged — agent code doesn't know it's in replay mode.

```
Normal:  Shem.LLM.complete(req)  →  [BudgetCheck, EventLogger, LlamaCppTransport]
Replay:  Shem.LLM.complete(req)  →  [BudgetCheck, EventLogger, ReplayTransport]
                                      ↑ injected per-process via process dictionary
```

**Pipeline swap mechanism:** `with_replay/2` stores a replay-specific pipeline in `Process.put(:shem_replay_pipeline, pipeline)`. `Shem.LLM.build_pipeline/0` checks the process dictionary first, falling back to `Application.get_env`. Cleanup via `try/after` guarantees the override is always removed. No other process is affected.

**Divergence model: permissive.** When a prompt differs from the original, `ReplayTransport` still serves the recorded content and records a `:llm_call_diverged` event. When the queue is exhausted, it records `:replay_exhausted` and returns `{:error, :replay_exhausted}` — halting that LLM call but preserving the replay session for inspection. Neither divergence nor exhaustion raises an exception.

---

## 3. Components

### 3.1 EventLogger patch (additive)

Two payload additions to `Shem.LLM.Middleware.EventLogger`:

- `:llm_call_started` → add `prompt: request.prompt`
- `:llm_call_completed` → add `content: response.content`

Sessions recorded before Phase 6a won't have these fields — `with_replay/2` detects this and returns `{:error, :no_llm_events}`.

### 3.2 `Shem.LLM.ReplayTransport.Server`

GenServer, same structural pattern as `StubTransport.Server`. State:

```elixir
%{
  queue: [{prompt, content, tokens_used} | {prompt, :error, reason}],
  call_index: non_neg_integer(),
  session_id: String.t() | nil
}
```

Public API:
- `start_link/1` — accepts `name:` opt
- `load/2` — loads the ordered queue extracted from original session events
- `pop/1` — returns `{:ok, entry} | :exhausted`

### 3.3 `Shem.LLM.ReplayTransport`

Terminal middleware (`@behaviour Shem.LLM.Middleware`). `call/3` logic:

1. `pop` from `ReplayTransport.Server`
2. If `:exhausted` → append `:replay_exhausted` event (`call_index`, `replay_prompt`), return `{:error, :replay_exhausted}`
3. If `{prompt, :error, reason}` → return `{:error, reason}` (replay the original failure)
4. If prompts match → return `{:ok, %Response{content: content, tokens_used: tokens_used, model: request.model, latency_ms: 0}}`
5. If prompts differ → append `:llm_call_diverged` event (`call_index`, `original_prompt`, `replay_prompt`, `recorded_content`), then return `{:ok, response}` (permissive — still serves recorded content)

`latency_ms` is `0` for replay responses — they're instantaneous by definition.

### 3.4 `Shem.LLM.Replay`

**`with_replay/2`:**

```elixir
@spec with_replay(String.t(), (String.t() -> result)) ::
  {:ok, String.t(), result} | {:error, term()}
  when result: term()
```

Steps:
1. Read all events from `original_session_id`
2. Return `{:error, :session_not_found | :session_ended | :no_llm_events}` if preconditions fail
3. Extract LLM call pairs in order → build queue of `{prompt, content, tokens_used}` tuples. Failed calls (`{prompt, :error, reason}`) are included.
4. Start `ReplayTransport.Server` (unique name, started directly — not supervised, short-lived)
5. Load queue into server; set `session_id` on server for divergence event appending
6. Build replay pipeline: `[{BudgetCheck, [budget_server: BudgetServer]}, {EventLogger, []}, {ReplayTransport, [server: server_name]}]`
7. `Process.put(:shem_replay_pipeline, replay_pipeline)`
8. `EventLog.start_session()` → `replay_session_id`
9. `result = fun.(replay_session_id)`
10. `try/after`: `Process.delete(:shem_replay_pipeline)`, `GenServer.stop(server_name)`
11. Return `{:ok, replay_session_id, result}`

**`diff/2`:**

```elixir
@spec diff(String.t(), String.t()) :: [divergence()]

@type divergence :: %{
  call_index: non_neg_integer(),
  type: :prompt_diverged | :replay_exhausted | :missing_in_replay | :missing_in_original,
  original: map() | nil,
  replay: map() | nil
}
```

Pure function: reads both session event logs, aligns LLM call events by `call_index`, returns a list of differences. Empty list means perfect reproduction — the regression assertion is `assert Replay.diff(golden_sid, new_sid) == []`.

---

## 4. Data Flow

**Extracting the recorded queue:**

Events from the original session are filtered to `:llm_call_started` / `:llm_call_completed` / `:llm_call_failed` pairs, matched in log order. Each pair yields one queue entry:

```elixir
# Success
{prompt: started.payload.prompt, content: completed.payload.content,
 tokens_used: completed.payload.tokens_used}

# Failure
{prompt: started.payload.prompt, error: failed.payload.reason}
```

**`with_replay/2` execution trace:**

```
with_replay("ses_original", fn replay_sid ->
  MyAgent.run(replay_sid)
end)

1. Extract queue → [{prompt1, content1, 42}, {prompt2, content2, 17}]
2. Start :replay_transport_abc
3. Process.put(:shem_replay_pipeline, [...ReplayTransport...])
4. EventLog.start_session() → "ses_replay_xyz"
5. fun.("ses_replay_xyz")
      └─► MyAgent calls Shem.LLM.complete(%Request{session_id: "ses_replay_xyz"})
               └─► build_pipeline() reads :shem_replay_pipeline from process dict
               └─► ReplayTransport.pop() → {prompt1, content1, 42}
               └─► compare prompts → match/diverge → return {:ok, %Response{}}
6. Process.delete(:shem_replay_pipeline)
7. GenServer.stop(:replay_transport_abc)
8. {:ok, "ses_replay_xyz", agent_result}
```

---

## 5. Error Handling

| Condition | Behaviour |
|---|---|
| Prompt differs from recorded | `:llm_call_diverged` event appended; recorded content still served (permissive) |
| Queue exhausted | `:replay_exhausted` event appended; `{:error, :replay_exhausted}` returned; replay session preserved |
| Original call was a failure | Same error returned; no divergence event |
| `original_session_id` not found | `{:error, :session_not_found}` — no replay session created |
| Original session has no LLM events | `{:error, :no_llm_events}` — session predates Phase 6a recording |
| `fun` raises exception | `try/after` cleans up process dict and stops server; exception re-raised; replay session preserved |
| `diff/2` on different-length sessions | Missing calls reported as `:missing_in_replay` or `:missing_in_original` diff entries |

---

## 6. New Event Types

| Type | Appended by | Payload |
|---|---|---|
| `:llm_call_diverged` | `ReplayTransport` | `%{call_index, original_prompt, replay_prompt, recorded_content}` |
| `:replay_exhausted` | `ReplayTransport` | `%{call_index, replay_prompt}` |

Existing event types unchanged (`:llm_call_started`, `:llm_call_completed`, `:llm_call_failed` payloads gain new fields — additive only).

---

## 7. Testing

**`ReplayTransport.Server`** (`async: true`, unique names):
- Queue loaded and popped in order
- Returns `:exhausted` when queue empty
- `call_index` increments per pop
- Error entries returned as-is

**`ReplayTransport` middleware** (`async: true`, injected server):
- Match path → content returned, no divergence event
- Diverge path → content returned AND `:llm_call_diverged` event appended
- Exhausted path → `:replay_exhausted` event, `{:error, :replay_exhausted}` returned
- Error entry path → original error returned

**`Shem.LLM.Replay`** (`async: false`, global EventLog):
- Happy path: two matching calls, `{:ok, replay_sid, result}`
- Divergence: different prompt, divergence event in replay log, result still returned
- Exhaustion: more calls than recorded, `{:ok, replay_sid, {:error, :replay_exhausted}}`
- Missing session: `{:error, :session_not_found}`
- No LLM events: `{:error, :no_llm_events}`
- Process dict cleaned up after `with_replay/2`
- Exception in fun: process dict cleared, server stopped, exception re-raised

**`Shem.LLM.Replay.diff/2`** (`async: true`, pure):
- Identical replay → `[]`
- One diverged call → single diff entry
- Exhausted replay → exhaustion entry
- Different session lengths → missing entries

**EventLogger regression** (`async: false`):
- `:llm_call_started` payload includes `prompt:`
- `:llm_call_completed` payload includes `content:`
- All existing EventLogger tests still pass

**Golden session fixture** (`async: false`, integration):
- Record a session with two known LLM exchanges via StubTransport
- Immediately replay it: `assert Replay.diff(original_sid, replay_sid) == []`
- Proves the full loop end-to-end

---

## 8. Out of Scope (Phase 6a)

- Timeline fork/branching with live continuation (Phase 6b)
- TUI replay mode / scrubber (Phase 6b or later)
- Partial replay (start from event N, not session start)
- Cross-session diff (more than two sessions)
- Replay of non-LLM events (tool calls, state mutations)
