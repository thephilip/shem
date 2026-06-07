# Phase 22 — Streaming LLM Responses Design

## Goal

Replace the current one-shot `LLM.complete/1` call in the agent loop with a streaming path that publishes tokens to subscribers as they arrive. Agents show live token output in the TUI and expose a Server-Sent Events endpoint for external consumers. The existing non-streaming path is untouched.

---

## Context

`LLM.stream/2` has been a stub since Phase 5 — it calls `complete/1` and fires the callback once with the full response. All four transports (`OpenAI`, `Anthropic`, `Ollama`, `LlamaCpp`) support native SSE streaming. The TUI currently shows `current_reasoning` only after `llm_call_completed` fires; there is no per-token display. The REST API has no streaming endpoint.

Phase 21 added native tool calling; the design here ensures streaming works cleanly alongside it — text tokens are streamed, tool_call JSON is accumulated silently.

---

## Design

### Delivery Mechanism: `Shem.StreamRegistry`

A single `Registry` process keyed by `session_id` with `keys: :duplicate`, allowing multiple concurrent subscribers (TUI + REST SSE handler) per agent session. Added to the supervision tree in `application.ex`.

```elixir
{Registry, keys: :duplicate, name: Shem.StreamRegistry}
```

Subscribers register with `Registry.register(Shem.StreamRegistry, session_id, nil)` and receive `{:stream_chunk, session_id, token}` messages as tokens arrive and `{:stream_done, session_id}` when the agent finishes.

---

### `LLM.Middleware` — Optional `stream/4` Callback

```elixir
@type chunk_fn :: (String.t() -> :ok)
@type stream_next :: (Request.t(), chunk_fn() -> pipeline_result())

@callback stream(
            request :: Request.t(),
            opts :: keyword(),
            chunk_fn :: chunk_fn(),
            next :: stream_next()
          ) :: {:ok, Response.t()} | {:error, term()}

@optional_callbacks stream: 4
```

If a middleware does not implement `stream/4`, the pipeline builder falls back to wrapping `call/3`: calls `next.(req, chunk_fn)` directly, passing the chunk_fn down to the terminal transport.

---

### `LLM.stream_complete/2`

New public function alongside `complete/1`:

```elixir
@spec stream_complete(Request.t(), chunk_fn()) :: {:ok, Response.t()} | {:error, term()}
def stream_complete(%Request{} = request, chunk_fn) do
  build_stream_pipeline(chunk_fn).(request)
end
```

`build_stream_pipeline/1` mirrors `build_pipeline/0` but wraps each middleware using `stream/4` when available, falling back to the pass-through wrapper otherwise. The returned `Response` is structurally identical to `complete/1` — same `content`, `tool_calls`, `tokens_used`, `latency_ms`.

---

### Non-Terminal Middlewares

**`BudgetCheck`** — `stream/4` checks the budget then calls `next.(req, chunk_fn)`. On return, deducts `tokens_used` from the response exactly as `call/3` does today.

**`EventLogger`** — `stream/4` appends `:llm_call_started`, calls `next.(req, chunk_fn)`, then appends `:llm_call_completed` with the final response. Identical to `call/3` aside from threading `chunk_fn`.

Both implementations are ~5 lines each.

---

### Transport Layer — SSE Streaming

All four transports implement `stream/4`. The shared contract:

1. Open the SSE connection with `Req.get` / `Req.post` with `into: :self` (Req delivers server-sent data to the calling process mailbox)
2. Loop over received chunks; call `chunk_fn.(text)` for each text token
3. Accumulate `content` (joined text) and `tool_calls` as side state
4. When the stream closes, return `{:ok, %Response{...}}` with the fully assembled response
5. When a tool_call chunk arrives mid-stream, **stop calling `chunk_fn`** — tool argument JSON is not human-readable and should not display. Continue accumulating silently.

Wire format per transport:

| Transport | Endpoint | Text chunk field | Tool-call detection |
|---|---|---|---|
| OpenAI | `/v1/chat/completions` + `"stream": true` | `choices[0].delta.content` | `choices[0].delta.tool_calls` present |
| LlamaCpp | `/v1/chat/completions` + `"stream": true` | `choices[0].delta.content` | `choices[0].delta.tool_calls` present |
| Anthropic | `/v1/messages` + `"stream": true` | `content_block_delta` event, `delta.text` | `content_block_start` with `type: "tool_use"` |
| Ollama | `/api/chat` + `"stream": true` | `message.content` | `message.tool_calls` on `done: true` chunk |

OpenAI and LlamaCpp are identical. Anthropic uses its own SSE event envelope. Ollama signals tool_calls only on the final chunk.

Token count: OpenAI/LlamaCpp/Anthropic include usage in the final SSE event; Ollama includes `eval_count` / `prompt_eval_count` on the `done: true` chunk — same fields as before.

---

### `Agent.Turn.stream_step/4`

Parallel to `step/4`, identical signature and return values:

```elixir
@spec stream_step(Config.t(), String.t(), [map()], [map()]) ::
        {:done, String.t()} | {:tool_calls, [tool_call()], String.t()} | {:error, term()}
def stream_step(config, session_id, history, manifest) do
  chunk_fn = fn token ->
    Registry.dispatch(Shem.StreamRegistry, session_id, fn entries ->
      Enum.each(entries, fn {pid, _} -> send(pid, {:stream_chunk, session_id, token}) end)
    end)
  end

  request =
    build_request(config.model, config.system_prompt, manifest, history)
    |> Map.put(:session_id, session_id)

  case LLM.stream_complete(request, chunk_fn) do
    {:ok, %Response{tool_calls: [_ | _] = calls, content: content}} ->
      {:tool_calls, calls, content || ""}

    {:ok, %Response{content: content}} ->
      content |> strip_thinking() |> parse_response()

    {:error, reason} ->
      {:error, reason}
  end
end
```

Return values are identical to `step/4`. `Agent.Server` replaces `Turn.step/4` with `Turn.stream_step/4` — one line change in `handle_info(:run_turn, ...)`. All history building, tool dispatch, and finish logic is unchanged.

---

### TUI — Live Token Display

`AgentView` gains one new field:

```elixir
streaming_buffer: String.t() | nil
```

`nil` when the agent is not actively generating; accumulates token text mid-generation.

The TUI's top-level `App` process registers with `Shem.StreamRegistry` for the active agent's `session_id` when it starts watching an agent:

```elixir
Registry.register(Shem.StreamRegistry, session_id, nil)
```

New `handle_info` clause in `App`:

```elixir
def handle_info({:stream_chunk, session_id, token}, state) do
  # append token to streaming_buffer for the matching agent view
  {:noreply, update_streaming_buffer(state, session_id, token)}
end
```

When `:llm_call_completed` arrives via EventLog (existing), `streaming_buffer` is cleared — `current_reasoning` takes over with the final content as before.

Render: `streaming_buffer` displays in the same slot as `current_reasoning`. Tokens accumulate in place; no new UI chrome.

Unregister from `StreamRegistry` when the agent reaches `:done` / `:error` or the user navigates away.

---

### REST SSE Endpoint

New: `GET /api/agents/:id/stream`

Plug handler:

```elixir
get "/:id/stream" do
  case Shem.Agent.session_id(id) do
    {:error, :not_found} ->
      send_json(conn, 404, %{error: "agent not found"})

    {:ok, session_id} ->
      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      Registry.register(Shem.StreamRegistry, session_id, nil)
      stream_loop(conn, session_id)
  end
end
```

SSE event format:

```
data: {"type":"chunk","content":"Let me"}\n\n
data: {"type":"chunk","content":" check the file"}\n\n
data: {"type":"tool_call","name":"shell"}\n\n
data: {"type":"done","status":"done"}\n\n
```

Three event types:
- `chunk` — token text (one or more characters)
- `tool_call` — emitted when a tool dispatch begins; includes the tool name but not args (args may be partial mid-stream)
- `done` — terminal event; includes final agent status (`"done"` or `"error"`)

`Agent.Server` broadcasts `{:stream_done, session_id}` to `Shem.StreamRegistry` in both `finish/3` clauses (`:answer` and the generic reason clause), so SSE handlers close cleanly regardless of how the agent ends. On client disconnect, the Plug handler unregisters from the Registry.

No authentication, no backpressure for Phase 22 — consistent with the existing REST API posture.

---

## File Map

| File | Action |
|---|---|
| `lib/shem/application.ex` | Add `Shem.StreamRegistry` to supervision tree |
| `lib/shem/llm/middleware.ex` | Add `stream/4` optional callback and `chunk_fn` / `stream_next` types |
| `lib/shem/llm.ex` | Add `stream_complete/2`; implement `build_stream_pipeline/1` |
| `lib/shem/llm/middleware/budget_check.ex` | Add `stream/4` — check budget, call next with chunk_fn |
| `lib/shem/llm/middleware/event_logger.ex` | Add `stream/4` — log start, call next, log completion |
| `lib/shem/llm/middleware/openai_transport.ex` | Add `stream/4` — SSE via `Req`, tool_call cutoff |
| `lib/shem/llm/middleware/anthropic_transport.ex` | Add `stream/4` — SSE with Anthropic event envelope |
| `lib/shem/llm/middleware/ollama_transport.ex` | Add `stream/4` — SSE, tool_calls on final chunk |
| `lib/shem/llm/middleware/llama_cpp_transport.ex` | Add `stream/4` — identical to OpenAI transport |
| `lib/shem/agent/turn.ex` | Add `stream_step/4` |
| `lib/shem/agent/server.ex` | Replace `Turn.step/4` with `Turn.stream_step/4`; broadcast `:stream_done` on finish |
| `lib/shem/tui/app.ex` | Register with StreamRegistry; handle `{:stream_chunk, ...}`; update render |
| `lib/shem/tui/agent_view.ex` | Add `streaming_buffer` field |
| `lib/shem/rest/handlers/agents.ex` | Add `GET /:id/stream` SSE endpoint |
| `test/shem/llm_test.exs` | Add `stream_complete/2` tests with mock chunk_fn |
| `test/shem/agent/turn_test.exs` | Add `stream_step/4` tests |
| `test/shem/llm/middleware/budget_check_test.exs` | Add streaming path tests |
| `test/shem/llm/middleware/event_logger_test.exs` | Add streaming path tests |
| `test/shem/llm/middleware/openai_transport_test.exs` | Add `stream/4` tests |
| `test/shem/llm/middleware/anthropic_transport_test.exs` | Add `stream/4` tests |
| `test/shem/llm/middleware/ollama_transport_test.exs` | Add `stream/4` tests |
| `test/shem/llm/middleware/llama_cpp_transport_test.exs` | Add `stream/4` tests |
| `test/shem/rest/handlers/agents_test.exs` | Add SSE endpoint test |

---

## Testing Strategy

- `LLM.stream_complete/2`: mock `chunk_fn` collects tokens into a list; assert list contents and final `Response`
- Transport `stream/4`: mock `http_post_fn` returns a sequence of SSE chunks as a stream; assert `chunk_fn` called per text token, not called for tool_call chunks; assert final `Response` matches expected shape
- `Turn.stream_step/4`: mock `LLM.stream_complete/2`; assert Registry receives chunks; assert return values identical to `step/4`
- REST SSE: start agent, connect to `/api/agents/:id/stream`, assert SSE events arrive with correct types; assert `done` event closes the stream
- All existing tests continue to pass — `complete/1` and `step/4` paths are untouched

---

## Future Work

- Streaming tool call arguments (partial JSON arriving via SSE) — requires detecting incomplete `arguments` strings and buffering until valid JSON
- Backpressure on the SSE endpoint for slow consumers
- Python SDK `stream()` method wrapping the SSE endpoint
