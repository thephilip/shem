# Reasoning Visibility — Design Spec
_2026-06-15_

## Problem

qwen3 (and any future thinking model) separates its output into two fields: `reasoning_content` (chain-of-thought) and `content` (the actual reply). The current stack discards `reasoning_content` entirely. This means:

- Thinking tokens are silently consumed against the token budget with no trace.
- The EventLog records what an agent *did* but not what it *was reasoning* when it decided to do it.
- Time-travel replay shows the skeleton of a session with the thinking stripped out.

## Goal

Capture the model's reasoning chain as a first-class event in the EventLog and surface it in the TUI and REST streaming interface. The durable record enables time-travel through an agent's internal monologue, not just its actions.

## Scope

Transport: `OpenAITransport` only (the only transport that produces `reasoning_content` today).
All other transports (`LlamaCppTransport`, `OllamaTransport`, `AnthropicTransport`) are unchanged — they naturally produce `reasoning_content: nil` from the struct default.

## Architecture

### 1. Data Model — `LLM.Response`

Add one optional field:

```elixir
defstruct [:content, :tool_calls, :reasoning_content, :tokens_used, :model, :latency_ms]
```

`reasoning_content` is `String.t() | nil`. nil means the transport produced no thinking (non-thinking models, or thinking disabled).

### 2. Transport — `OpenAITransport`

**Non-streaming path (`parse_response/3`)**

Read `message["reasoning_content"]` alongside `message["content"]`. Treat empty string as nil. Write into `Response.reasoning_content`.

**Streaming path (SSE accumulator + `apply_openai_chunk/3`)**

The accumulator state gains one field: `reasoning_content: ""`.

`apply_openai_chunk` already has two delta branches: `content` and `tool_calls`. A third branch handles `delta["reasoning_content"]` — accumulate it the same way content is accumulated (binary concatenation). Do not call `chunk_fn` for thinking tokens; only content tokens are streamed live.

`assemble_openai_response` writes the accumulated `reasoning_content` string into the Response. Empty string → nil.

No other transports change.

### 3. Turn — `Turn.stream_step` and `Turn.step`

Both functions extract `response.reasoning_content` after the LLM call and thread it through as a trailing element in the return tuple:

```
{:done, content, reasoning_content | nil}
{:tool_calls, calls, raw, reasoning_content | nil}
{:error, reason}   # unchanged
```

This is an internal API — only `Agent.Server` pattern-matches on these tuples.

### 4. Agent.Server — EventLog + pg broadcast

After each step result, if `reasoning_content` is a non-empty string:

1. **EventLog event** (before `:agent_turn_completed`):
   ```elixir
   EventLog.append(session_id, :agent_thinking, %{
     content: reasoning_content,
     turn: turn_count + 1
   })
   ```
   Ordering: `:agent_thinking` → `:agent_turn_completed`. Thinking is always anchored before outcome in the log.

2. **pg broadcast**:
   ```elixir
   Enum.each(:pg.get_members(:shem_streams, session_id), fn pid ->
     send(pid, {:stream_thinking, session_id, reasoning_content})
   end)
   ```
   Same pattern as `broadcast_stream_done/1`. Emitted once per turn, after the full stream completes.

### 5. TUI — `StreamSink` + agent panel

`StreamSink` gains:
- `thinking: nil` in state
- `handle_info({:stream_thinking, _sid, rc}, state)` — stores rc, replaces any prior value for this turn
- `take_thinking/1` — returns and clears the stored thinking string (nil if none)

Agent panel rendering: call `take_thinking` before rendering the content block. If non-nil, render a thinking block above the content — dimmed attribute, prefixed with `▸ thinking`. Show the first 120 characters of the first line, appending `…` if longer. Full text is in the EventLog.

No collapsible panel in this phase — that's a future TUI refinement.

### 6. REST SSE — `Agents` handler

The receive loop in the streaming endpoint adds a clause:

```elixir
{:stream_thinking, ^session_id, rc} ->
  chunk.(["event: thinking\ndata: ", rc, "\n\n"])
  loop.()
```

Positioned between the `stream_chunk` and `stream_done` handlers. API consumers can filter by event type; existing consumers that ignore unknown event types are unaffected.

## Event Log Schema

New event type: `:agent_thinking`

```elixir
%{
  type: :agent_thinking,
  session_id: session_id,
  payload: %{
    content: "...",   # full reasoning_content string
    turn: integer()   # 1-based turn number
  }
}
```

## Ordering Invariant

Per-turn event order in the EventLog:

```
:agent_turn_started
:agent_thinking          ← new, present only when model produces reasoning
:agent_tool_called       ← 0 or more
:agent_tool_result       ← paired with each tool_called
:agent_turn_completed
```

## What This Enables

- **Time-travel through reasoning**: replay a session and see the model's chain-of-thought at each turn, not just its decisions.
- **Fork at a reasoning step**: scrub to a `:agent_thinking` event, fork the timeline, and run the agent again from that point with a different context.
- **Debugging tool calls**: when an agent calls the wrong tool, the thinking event shows *why* it chose that tool.
- **No Hermes equivalent**: Hermes has no concept of persisting model reasoning as a first-class event. This is structurally impossible in frameworks that don't own the event log.

## Out of Scope

- Real-time streaming of thinking tokens (token-by-token) — thinking is emitted as a complete block after the stream finishes.
- Collapsible TUI panel — future refinement.
- `LlamaCppTransport` thinking support — not applicable; llama.cpp does not produce `reasoning_content`.
- Configurable thinking suppression (e.g. `enable_thinking: false` in request body) — deferred; adjust `llm_max_tokens` in config as a workaround for now.
