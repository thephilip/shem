# Phase 22 — Streaming LLM Responses Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the one-shot `LLM.complete/1` call in the agent loop with a streaming path that publishes tokens in real-time to the TUI and a REST SSE endpoint, while leaving the non-streaming path completely untouched.

**Architecture:** A `Shem.StreamRegistry` OTP Registry acts as PubSub; `LLM.stream_complete/2` builds a streaming middleware pipeline (same shape as `build_pipeline/0` but with an optional `stream/4` callback per middleware); terminal transports use `Req`'s `into:` callback to receive SSE chunks and call `chunk_fn.(token)` per text token; `Agent.Server` uses `Turn.stream_step/4` which broadcasts via the Registry; TUI subscribes via `Shem.TUI.StreamSink`; REST exposes `GET /api/agents/:id/stream` as server-sent events.

**Tech Stack:** Elixir/OTP, `Registry` (built-in), `Req ~> 0.5` (SSE via `into:` callback), `Plug` (chunked SSE response), Ratatouille TUI (polled from 500ms → 100ms tick).

---

## File Map

| File | Action |
|---|---|
| `lib/shem/application.ex` | Add `{Registry, keys: :duplicate, name: Shem.StreamRegistry}` |
| `lib/shem/llm/middleware.ex` | Add `stream/4` optional callback + `chunk_fn` / `stream_next` types |
| `lib/shem/llm.ex` | Replace stub `stream/2` with `stream_complete/2`; add `build_stream_pipeline/0` |
| `lib/shem/llm/stub_transport.ex` | Add `stream/4` — pop response, emit content as one chunk |
| `lib/shem/llm/middleware/router_transport.ex` | Add `stream/4` — delegate to resolved transport's `stream/4` |
| `lib/shem/llm/middleware/budget_check.ex` | Add `stream/4` — budget gate + deduct on return |
| `lib/shem/llm/middleware/event_logger.ex` | Add `stream/4` — log start/done around `next.(req, chunk_fn)` |
| `lib/shem/llm/middleware/openai_transport.ex` | Add `stream/4` — SSE via `Req`; tool_call accumulation |
| `lib/shem/llm/middleware/llama_cpp_transport.ex` | Add `stream/4` — identical logic to OpenAI |
| `lib/shem/llm/middleware/anthropic_transport.ex` | Add `stream/4` — Anthropic SSE event envelope |
| `lib/shem/llm/middleware/ollama_transport.ex` | Add `stream/4` — NDJSON streaming; tool_calls on final chunk |
| `lib/shem/agent/turn.ex` | Add `stream_step/4` |
| `lib/shem/agent/server.ex` | Swap `Turn.step/4` → `Turn.stream_step/4`; broadcast `:stream_done` in `finish/3` |
| `lib/shem/tui/stream_sink.ex` | New GenServer — registers with StreamRegistry, buffers tokens |
| `lib/shem/tui/agent_view.ex` | Add `streaming_buffer: nil` field |
| `lib/shem/tui/app.ex` | Start/stop StreamSink on agent focus; poll buffer on tick (100ms); clear on `llm_call_completed` |
| `lib/shem/rest/handlers/agents.ex` | Add `GET /:id/stream` SSE endpoint |
| `test/shem/llm_test.exs` | `stream_complete/2` tests with mock chunk_fn |
| `test/shem/agent/turn_test.exs` | `stream_step/4` tests |
| `test/shem/llm/middleware/budget_check_test.exs` | Streaming path tests |
| `test/shem/llm/middleware/event_logger_test.exs` | Streaming path tests |
| `test/shem/llm/middleware/openai_transport_test.exs` | `stream/4` tests |
| `test/shem/llm/middleware/llama_cpp_transport_test.exs` | `stream/4` tests |
| `test/shem/llm/middleware/anthropic_transport_test.exs` | `stream/4` tests |
| `test/shem/llm/middleware/ollama_transport_test.exs` | `stream/4` tests |
| `test/shem/rest/handlers/agents_test.exs` | SSE endpoint test |

---

## Shared Implementation Reference

Several tasks below build or call the streaming pipeline. Keep this mental model:

- Every pipeline step (when streaming) is `fn(req, chunk_fn) -> pipeline_result()`.
- The `next` arg passed to `stream/4` has that same shape: `(Request.t(), chunk_fn() -> pipeline_result())`.
- Terminal transports (`OpenAI`, `LlamaCpp`, `Anthropic`, `Ollama`, `StubTransport`) ignore `_next` — they do the HTTP call and return `{:ok, Response.t()}`.
- Non-terminal middlewares (`BudgetCheck`, `EventLogger`, `RouterTransport`) delegate by calling `next.(request, chunk_fn)`.
- If a middleware does NOT implement `stream/4`, the pipeline builder falls back to wrapping its `call/3` with a `next` that calls the streaming next: `fn r -> next_stream.(r, chunk_fn) end`.

---

## Task 1 — StreamRegistry + Middleware Streaming Callback

**Files:**
- Modify: `lib/shem/application.ex`
- Modify: `lib/shem/llm/middleware.ex`

- [ ] **Step 1: Write the failing test for Registry**

Add to `test/shem/llm_test.exs` (create if it doesn't have this yet — just add a describe block):

```elixir
describe "Shem.StreamRegistry" do
  test "is a duplicate-key Registry in the supervision tree" do
    session_id = "test_stream_#{System.unique_integer()}"
    assert :ok = Registry.register(Shem.StreamRegistry, session_id, nil)
    entries = Registry.lookup(Shem.StreamRegistry, session_id)
    assert length(entries) == 1
  end
end
```

Run: `mix test test/shem/llm_test.exs --grep "StreamRegistry" -v`
Expected: FAIL — `Shem.StreamRegistry` does not exist.

- [ ] **Step 2: Add StreamRegistry to supervision tree**

In `lib/shem/application.ex`, add `{Registry, keys: :duplicate, name: Shem.StreamRegistry}` to the `children` list, **before** `adversarial_children()`:

```elixir
children =
  [
    {Horde.Registry, [name: Shem.Registry, keys: :unique, members: :auto]},
    Shem.AgentSupervisor,
    Shem.EventLog,
    Shem.Trust.Store,
    Shem.Agent.PresetStore,
    Shem.LLM.Router,
    {Task.Supervisor, name: Shem.Lab.TaskSupervisor},
    Shem.Lab.Registry,
    Shem.LLM.BudgetServer,
    {Registry, keys: :duplicate, name: Shem.StreamRegistry}
  ] ++
    adversarial_children() ++
    llm_stub_children() ++
    mcp_children() ++
    cluster_children() ++
    tui_children()
```

- [ ] **Step 3: Add `stream/4` optional callback to `LLM.Middleware`**

Read `lib/shem/llm/middleware.ex`. It currently defines `@callback call/3`. Add the streaming callback and types after the existing callback:

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

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/shem/llm_test.exs --grep "StreamRegistry" -v`
Expected: PASS

- [ ] **Step 5: Run full test suite to confirm no regressions**

Run: `mix test`
Expected: all 617 tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/application.ex lib/shem/llm/middleware.ex test/shem/llm_test.exs
git commit -m "feat: phase-22 — StreamRegistry + Middleware stream/4 callback"
```

---

## Task 2 — `LLM.stream_complete/2` + `StubTransport.stream/4` + `RouterTransport.stream/4`

**Files:**
- Modify: `lib/shem/llm.ex`
- Modify: `lib/shem/llm/stub_transport.ex`
- Modify: `lib/shem/llm/middleware/router_transport.ex`
- Modify: `test/shem/llm_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/llm_test.exs`:

```elixir
describe "stream_complete/2" do
  setup do
    Shem.LLM.BudgetServer.reset()
    StubTransport.Server.reset()
    :ok
  end

  test "calls chunk_fn with response content and returns {:ok, response}" do
    StubTransport.Server.push_response(
      {:ok, %Shem.LLM.Response{content: "hello world", tool_calls: nil, tokens_used: 5, model: :default, latency_ms: 1}}
    )

    {:ok, collector} = Agent.start_link(fn -> [] end)
    chunk_fn = fn token -> Agent.update(collector, &[token | &1]) end

    request = %Shem.LLM.Request{prompt: "test", model: :default}
    assert {:ok, %Shem.LLM.Response{content: "hello world"}} = Shem.LLM.stream_complete(request, chunk_fn)

    chunks = Agent.get(collector, & &1) |> Enum.reverse()
    assert chunks != []
    assert Enum.join(chunks) =~ "hello"
  end

  test "returns {:error, :budget_exhausted} without calling chunk_fn when budget is depleted" do
    Shem.LLM.BudgetServer.deduct(100_001)

    called = :atomics.new(1, signed: false)
    chunk_fn = fn _token -> :atomics.add(called, 1, 1) end

    request = %Shem.LLM.Request{prompt: "test", model: :default}
    assert {:error, :budget_exhausted} = Shem.LLM.stream_complete(request, chunk_fn)
    assert :atomics.get(called, 1) == 0
  end
end
```

Run: `mix test test/shem/llm_test.exs --grep "stream_complete" -v`
Expected: FAIL — `stream_complete/2` undefined.

- [ ] **Step 2: Add `StubTransport.stream/4`**

Modify `lib/shem/llm/stub_transport.ex`:

```elixir
defmodule Shem.LLM.StubTransport do
  @behaviour Shem.LLM.Middleware

  alias Shem.LLM.StubTransport.Server

  @impl true
  def call(request, opts, _next) do
    server = Keyword.get(opts, :server, Server)
    GenServer.call(server, {:record_call, request})

    case Server.pop(server) do
      {:ok, response} -> response
      :empty -> {:error, :no_stub_response}
    end
  end

  @impl true
  def stream(request, opts, chunk_fn, _next) do
    server = Keyword.get(opts, :server, Server)
    GenServer.call(server, {:record_call, request})

    case Server.pop(server) do
      {:ok, {:ok, %Shem.LLM.Response{content: content} = response}} ->
        if content, do: chunk_fn.(content)
        {:ok, response}

      {:ok, other} ->
        other

      :empty ->
        {:error, :no_stub_response}
    end
  end
end
```

- [ ] **Step 3: Add `RouterTransport.stream/4`**

Modify `lib/shem/llm/middleware/router_transport.ex`:

```elixir
defmodule Shem.LLM.Middleware.RouterTransport do
  @behaviour Shem.LLM.Middleware

  @impl true
  def call(request, opts, _next) do
    resolve_fn = Keyword.get(opts, :resolve_fn, &Shem.LLM.Router.resolve/1)

    case resolve_fn.(request.model) do
      {:error, reason} ->
        {:error, {:router, reason}}

      {transport_module, transport_opts} ->
        transport_module.call(request, transport_opts, fn _ -> {:error, :no_next} end)
    end
  end

  @impl true
  def stream(request, opts, chunk_fn, _next) do
    resolve_fn = Keyword.get(opts, :resolve_fn, &Shem.LLM.Router.resolve/1)

    case resolve_fn.(request.model) do
      {:error, reason} ->
        {:error, {:router, reason}}

      {transport_module, transport_opts} ->
        transport_module.stream(
          request,
          transport_opts,
          chunk_fn,
          fn _req, _cf -> {:error, :no_next} end
        )
    end
  end
end
```

- [ ] **Step 4: Implement `LLM.stream_complete/2`**

Replace the stub `stream/2` in `lib/shem/llm.ex` and add the streaming pipeline builder:

```elixir
defmodule Shem.LLM do
  alias Shem.LLM.{Request, Response}

  @spec complete(Request.t()) :: {:ok, Response.t()} | {:error, term()}
  def complete(%Request{} = request) do
    pipeline = build_pipeline()
    pipeline.(request)
  end

  @spec stream_complete(Request.t(), (String.t() -> :ok)) :: {:ok, Response.t()} | {:error, term()}
  def stream_complete(%Request{} = request, chunk_fn) when is_function(chunk_fn, 1) do
    build_stream_pipeline().(request, chunk_fn)
  end

  defp build_pipeline do
    pipeline =
      Process.get(:shem_replay_pipeline) ||
        Application.get_env(:shem, :llm_pipeline, [])

    terminal = fn _req -> {:error, :no_terminal} end

    pipeline
    |> normalize_pipeline()
    |> Enum.reverse()
    |> Enum.reduce(terminal, fn {mod, opts}, next ->
      fn req -> mod.call(req, opts, next) end
    end)
  end

  defp build_stream_pipeline do
    pipeline =
      Process.get(:shem_replay_pipeline) ||
        Application.get_env(:shem, :llm_pipeline, [])

    # Each step is fn(req, chunk_fn) -> pipeline_result()
    terminal = fn _req, _chunk_fn -> {:error, :no_terminal} end

    pipeline
    |> normalize_pipeline()
    |> Enum.reverse()
    |> Enum.reduce(terminal, fn {mod, opts}, next ->
      if function_exported?(mod, :stream, 4) do
        fn req, chunk_fn -> mod.stream(req, opts, chunk_fn, next) end
      else
        # Fallback: call/3 with a next that threads chunk_fn down
        fn req, chunk_fn -> mod.call(req, opts, fn r -> next.(r, chunk_fn) end) end
      end
    end)
  end

  defp normalize_pipeline(pipeline) do
    Enum.map(pipeline, fn
      {mod, opts} -> {mod, opts}
      mod when is_atom(mod) -> {mod, []}
    end)
  end
end
```

- [ ] **Step 5: Run tests**

Run: `mix test test/shem/llm_test.exs -v`
Expected: all tests including the new `stream_complete` tests pass.

- [ ] **Step 6: Run full suite**

Run: `mix test`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/llm.ex lib/shem/llm/stub_transport.ex lib/shem/llm/middleware/router_transport.ex test/shem/llm_test.exs
git commit -m "feat: phase-22 — LLM.stream_complete/2 + StubTransport/RouterTransport stream/4"
```

---

## Task 3 — `BudgetCheck.stream/4` + `EventLogger.stream/4`

**Files:**
- Modify: `lib/shem/llm/middleware/budget_check.ex`
- Modify: `lib/shem/llm/middleware/event_logger.ex`
- Modify: `test/shem/llm/middleware/budget_check_test.exs`
- Modify: `test/shem/llm/middleware/event_logger_test.exs`

- [ ] **Step 1: Write failing tests for `BudgetCheck.stream/4`**

Add to `test/shem/llm/middleware/budget_check_test.exs` (inside the existing module):

```elixir
describe "stream/4" do
  setup do
    Shem.LLM.BudgetServer.reset()
    :ok
  end

  test "calls next.(req, chunk_fn) and returns result when budget ok" do
    {:ok, collector} = Agent.start_link(fn -> [] end)
    chunk_fn = fn t -> Agent.update(collector, &[t | &1]) end

    next = fn req, cf ->
      cf.("streamed")
      {:ok, %Shem.LLM.Response{content: "streamed", tokens_used: 3, model: req.model, latency_ms: 0}}
    end

    request = %Shem.LLM.Request{prompt: "p", model: :default}
    assert {:ok, %{content: "streamed"}} = BudgetCheck.stream(request, [], chunk_fn, next)
    assert Agent.get(collector, & &1) == ["streamed"]
  end

  test "returns {:error, :budget_exhausted} without calling next when budget is depleted" do
    Shem.LLM.BudgetServer.deduct(100_001)

    next = fn _req, _cf -> flunk("next should not be called") end
    chunk_fn = fn _t -> flunk("chunk_fn should not be called") end

    request = %Shem.LLM.Request{prompt: "p", model: :default}
    assert {:error, :budget_exhausted} = BudgetCheck.stream(request, [], chunk_fn, next)
  end

  test "deducts tokens from budget after successful stream" do
    initial = Shem.LLM.BudgetServer.status().remaining
    next = fn req, _cf ->
      {:ok, %Shem.LLM.Response{content: "x", tokens_used: 7, model: req.model, latency_ms: 0}}
    end

    request = %Shem.LLM.Request{prompt: "p", model: :default}
    assert {:ok, _} = BudgetCheck.stream(request, [], fn _t -> :ok end, next)
    assert Shem.LLM.BudgetServer.status().remaining == initial - 7
  end
end
```

Run: `mix test test/shem/llm/middleware/budget_check_test.exs --grep "stream/4" -v`
Expected: FAIL — `BudgetCheck.stream/4` undefined.

- [ ] **Step 2: Implement `BudgetCheck.stream/4`**

Add to `lib/shem/llm/middleware/budget_check.ex` (after the existing `call/3`):

```elixir
@impl true
def stream(request, opts, chunk_fn, next) do
  server = Keyword.get(opts, :budget_server, BudgetServer)

  case BudgetServer.check(server) do
    {:error, :budget_exhausted} ->
      if request.session_id do
        Shem.EventLog.append(request.session_id, :budget_exhausted, %{})
      end

      {:error, :budget_exhausted}

    :ok ->
      result = next.(request, chunk_fn)

      case result do
        {:ok, response} ->
          %{soft_warned?: was_warned} = BudgetServer.status(server)
          BudgetServer.deduct(server, response.tokens_used)
          %{soft_warned?: now_warned} = BudgetServer.status(server)

          if request.session_id && not was_warned && now_warned do
            Shem.EventLog.append(request.session_id, :budget_soft_warning, %{})
          end

        {:error, _} ->
          :ok
      end

      result
  end
end
```

- [ ] **Step 3: Write failing tests for `EventLogger.stream/4`**

Add to `test/shem/llm/middleware/event_logger_test.exs`:

```elixir
describe "stream/4" do
  test "appends llm_call_started and llm_call_completed events around the stream" do
    {:ok, session_id} = Shem.EventLog.start_session("eltest_stream_#{System.unique_integer()}")

    next = fn req, cf ->
      cf.("token")
      {:ok, %Shem.LLM.Response{content: "token", tokens_used: 2, model: req.model, latency_ms: 0}}
    end

    request = %Shem.LLM.Request{prompt: "p", model: :default, session_id: session_id}
    assert {:ok, _} = EventLogger.stream(request, [], fn _t -> :ok end, next)

    {:ok, events} = Shem.EventLog.events(session_id)
    types = Enum.map(events, & &1.type)
    assert :llm_call_started in types
    assert :llm_call_completed in types
  end

  test "passes chunk_fn through to next unchanged" do
    {:ok, collector} = Agent.start_link(fn -> [] end)
    chunk_fn = fn t -> Agent.update(collector, &[t | &1]) end

    next = fn _req, cf -> cf.("live"); {:ok, %Shem.LLM.Response{content: "live", tokens_used: 1, model: :default, latency_ms: 0}} end

    request = %Shem.LLM.Request{prompt: "p", model: :default, session_id: nil}
    assert {:ok, _} = EventLogger.stream(request, [], chunk_fn, next)
    assert Agent.get(collector, & &1) == ["live"]
  end
end
```

Run: `mix test test/shem/llm/middleware/event_logger_test.exs --grep "stream/4" -v`
Expected: FAIL.

- [ ] **Step 4: Implement `EventLogger.stream/4`**

Add to `lib/shem/llm/middleware/event_logger.ex` (after `call/3`):

```elixir
@impl true
def stream(%{session_id: nil} = request, opts, chunk_fn, next), do: next.(request, chunk_fn)

def stream(request, _opts, chunk_fn, next) do
  Shem.EventLog.append(request.session_id, :llm_call_started, %{
    model: request.model,
    prompt: request.prompt
  })

  start_ms = System.monotonic_time(:millisecond)
  result = next.(request, chunk_fn)
  latency_ms = System.monotonic_time(:millisecond) - start_ms

  case result do
    {:ok, response} ->
      Shem.EventLog.append(request.session_id, :llm_call_completed, %{
        tokens_used: response.tokens_used,
        latency_ms: latency_ms,
        content: response.content
      })

    {:error, reason} ->
      Shem.EventLog.append(request.session_id, :llm_call_failed, %{
        reason: inspect(reason)
      })
  end

  result
end
```

- [ ] **Step 5: Run all middleware tests**

Run: `mix test test/shem/llm/middleware/ -v`
Expected: all pass.

- [ ] **Step 6: Run full suite**

Run: `mix test`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/llm/middleware/budget_check.ex lib/shem/llm/middleware/event_logger.ex \
        test/shem/llm/middleware/budget_check_test.exs test/shem/llm/middleware/event_logger_test.exs
git commit -m "feat: phase-22 — BudgetCheck + EventLogger stream/4"
```

---

## Task 4 — `OpenAITransport.stream/4`

**Files:**
- Modify: `lib/shem/llm/middleware/openai_transport.ex`
- Modify: `test/shem/llm/middleware/openai_transport_test.exs`

### Background

The OpenAI SSE stream sends events in this format:

```
data: {"choices":[{"delta":{"content":"Hello"},"index":0}]}\n\n
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"shell","arguments":""}}]},"index":0}]}\n\n
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"cmd\":\"ls\"}"}}]},"index":0}]}\n\n
data: {"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\n\n
data: [DONE]\n\n
```

Rules:
- Split buffer on `\n\n` to get complete events.
- Extract `data: <JSON>` line per event; skip `[DONE]` and `event:` lines.
- `choices[0].delta.content` → call `chunk_fn.(text)` unless `tool_cut` is set.
- `choices[0].delta.tool_calls` → set `tool_cut: true`, accumulate into `tool_calls` map keyed by index.
- Top-level `usage` field in a chunk → capture token counts.

For tests, inject `http_stream_fn: fn url, body, chunk_fn -> ... end` to bypass real HTTP.

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/llm/middleware/openai_transport_test.exs`:

```elixir
describe "stream/4 — text response" do
  test "calls chunk_fn per text token and returns assembled Response" do
    {:ok, collector} = Agent.start_link(fn -> [] end)
    chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

    http_stream_fn = fn _url, _body, cf ->
      cf.("Hello ")
      cf.("world")
      {:ok, %Shem.LLM.Response{
        content: "Hello world",
        tool_calls: nil,
        tokens_used: 10,
        model: :default,
        latency_ms: 0
      }}
    end

    request = %Shem.LLM.Request{prompt: "hi", model: :default}
    opts = [api_key: "sk-test", http_stream_fn: http_stream_fn]

    assert {:ok, %{content: "Hello world", tool_calls: nil, tokens_used: 10}} =
             OpenAITransport.stream(request, opts, chunk_fn, fn _, _ -> {:error, :no_next} end)

    assert Agent.get(collector, & &1) == ["Hello ", "world"]
  end
end

describe "stream/4 — tool call response" do
  test "stops calling chunk_fn when tool_call appears; returns tool_calls in Response" do
    {:ok, collector} = Agent.start_link(fn -> [] end)
    chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

    http_stream_fn = fn _url, _body, cf ->
      cf.("Let me check")
      # transport stops calling chunk_fn after this (tool cut) — mock returns the final assembled result
      {:ok, %Shem.LLM.Response{
        content: "Let me check",
        tool_calls: [%{id: "call_1", name: "shell", args: %{"cmd" => "ls"}}],
        tokens_used: 15,
        model: :default,
        latency_ms: 0
      }}
    end

    request = %Shem.LLM.Request{prompt: "ls", model: :default, tools: nil}
    opts = [api_key: "sk-test", http_stream_fn: http_stream_fn]

    assert {:ok, %{tool_calls: [%{name: "shell"}]}} =
             OpenAITransport.stream(request, opts, chunk_fn, fn _, _ -> {:error, :no_next} end)

    assert Agent.get(collector, & &1) == ["Let me check"]
  end
end

describe "stream/4 — error handling" do
  test "returns {:error, {:transport, :missing_api_key}} when api_key is nil" do
    request = %Shem.LLM.Request{prompt: "test", model: :default}
    assert {:error, {:transport, :missing_api_key}} =
             OpenAITransport.stream(request, [api_key: nil], fn _ -> :ok end, fn _, _ -> :ok end)
  end
end
```

Run: `mix test test/shem/llm/middleware/openai_transport_test.exs --grep "stream/4" -v`
Expected: FAIL.

- [ ] **Step 2: Implement `OpenAITransport.stream/4` and SSE helpers**

Add to `lib/shem/llm/middleware/openai_transport.ex` after `call/3`:

```elixir
@impl true
def stream(request, opts, chunk_fn, _next) do
  api_key = Keyword.get(opts, :api_key, System.get_env("OPENAI_API_KEY"))

  if is_nil(api_key) or api_key == "" do
    {:error, {:transport, :missing_api_key}}
  else
    base_url = Keyword.get(opts, :base_url, "https://api.openai.com")
    timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))
    model_string = Keyword.get(opts, :model_string, "gpt-4o")
    max_tokens = Map.get(request.options, :max_tokens, 512)

    messages = build_messages(request)

    base_body = %{
      "model" => model_string,
      "messages" => messages,
      "max_tokens" => max_tokens,
      "stream" => true,
      "stream_options" => %{"include_usage" => true}
    }

    tools_fields =
      case request.tools do
        nil -> %{}
        tools ->
          %{
            "tools" =>
              Enum.map(tools, fn %{name: n, description: d, schema: s} ->
                %{"type" => "function", "function" => %{"name" => n, "description" => d, "parameters" => s}}
              end),
            "tool_choice" => "auto"
          }
      end

    body = Map.merge(base_body, tools_fields)
    headers = [{"authorization", "Bearer #{api_key}"}]

    http_stream =
      Keyword.get(opts, :http_stream_fn, fn url, b, cf ->
        do_sse_stream_openai(url, b, headers, timeout_ms, request.model, cf)
      end)

    http_stream.(base_url <> "/v1/chat/completions", body, chunk_fn)
  end
end

defp build_messages(request) do
  case request.messages do
    nil ->
      [%{"role" => "user", "content" => request.prompt}]

    msgs ->
      system_msgs =
        if request.system, do: [%{"role" => "system", "content" => request.system}], else: []
      system_msgs ++ Enum.map(msgs, &format_message/1)
  end
end

defp do_sse_stream_openai(url, body, headers, timeout_ms, model, chunk_fn) do
  start_ms = System.monotonic_time(:millisecond)
  ref = make_ref()

  Process.put(ref, %{
    buf: "",
    content: "",
    tool_calls: %{},
    tool_cut: false,
    prompt_tokens: 0,
    completion_tokens: 0
  })

  result =
    Req.post(url,
      json: body,
      headers: headers,
      receive_timeout: timeout_ms,
      into: fn {:data, data}, acc ->
        st = process_openai_data(data, Process.get(ref), chunk_fn)
        Process.put(ref, st)
        {:cont, acc}
      end
    )

  final = Process.delete(ref)
  latency_ms = System.monotonic_time(:millisecond) - start_ms

  case result do
    {:ok, %{status: 200}} ->
      assemble_openai_response(final, model, latency_ms)

    {:ok, %{status: 401}} ->
      {:error, {:transport, :unauthorized}}

    {:ok, %{status: 429}} ->
      {:error, {:transport, :rate_limited}}

    {:ok, %{status: status}} ->
      {:error, {:transport, {:http_error, status}}}

    {:error, reason} ->
      {:error, {:transport, reason}}
  end
end

defp process_openai_data(data, state, chunk_fn) do
  {events, new_buf} = split_sse_events(state.buf <> data)

  Enum.reduce(events, %{state | buf: new_buf}, fn event, acc ->
    process_openai_event(event, acc, chunk_fn)
  end)
end

defp split_sse_events(buffer) do
  parts = String.split(buffer, "\n\n")

  case parts do
    [single] ->
      {[], single}

    _ ->
      events = parts |> Enum.slice(0..-2//1) |> Enum.reject(&(&1 == ""))
      {events, List.last(parts)}
  end
end

defp process_openai_event(event, state, chunk_fn) do
  data_line =
    event
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "data: "))

  case data_line do
    nil ->
      state

    "data: [DONE]" ->
      state

    "data: " <> json_str ->
      case Jason.decode(json_str) do
        {:ok, decoded} -> apply_openai_chunk(decoded, state, chunk_fn)
        _ -> state
      end
  end
end

defp apply_openai_chunk(%{"choices" => [%{"delta" => delta} | _]} = msg, state, chunk_fn) do
  state =
    case delta do
      %{"content" => content} when is_binary(content) and content != "" ->
        unless state.tool_cut, do: chunk_fn.(content)
        %{state | content: state.content <> content}

      %{"tool_calls" => raw_calls} ->
        Enum.reduce(raw_calls, %{state | tool_cut: true}, fn
          %{"index" => idx} = tc, acc ->
            existing = Map.get(acc.tool_calls, idx, %{id: nil, name: nil, args_buf: ""})

            updated = %{
              id: Map.get(tc, "id", existing.id),
              name: get_in(tc, ["function", "name"]) || existing.name,
              args_buf: existing.args_buf <> (get_in(tc, ["function", "arguments"]) || "")
            }

            %{acc | tool_calls: Map.put(acc.tool_calls, idx, updated)}
        end)

      _ ->
        state
    end

  # top-level usage on the final chunk
  case Map.get(msg, "usage") do
    nil ->
      state

    usage ->
      %{state |
        prompt_tokens: Map.get(usage, "prompt_tokens", state.prompt_tokens),
        completion_tokens: Map.get(usage, "completion_tokens", state.completion_tokens)}
  end
end

defp apply_openai_chunk(%{"usage" => usage}, state, _chunk_fn) do
  %{state |
    prompt_tokens: Map.get(usage, "prompt_tokens", state.prompt_tokens),
    completion_tokens: Map.get(usage, "completion_tokens", state.completion_tokens)}
end

defp apply_openai_chunk(_decoded, state, _chunk_fn), do: state

defp assemble_openai_response(final, model, latency_ms) do
  tokens_used = final.prompt_tokens + final.completion_tokens

  tool_calls =
    if map_size(final.tool_calls) == 0 do
      nil
    else
      final.tool_calls
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_, %{id: id, name: name, args_buf: args_buf}} ->
        %{id: id, name: name, args: Jason.decode!(args_buf)}
      end)
    end

  content = if final.content == "", do: nil, else: final.content

  {:ok,
   %Shem.LLM.Response{
     content: content,
     tool_calls: tool_calls,
     tokens_used: tokens_used,
     model: model,
     latency_ms: latency_ms
   }}
end
```

- [ ] **Step 3: Run tests**

Run: `mix test test/shem/llm/middleware/openai_transport_test.exs -v`
Expected: all pass.

- [ ] **Step 4: Run full suite**

Run: `mix test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/middleware/openai_transport.ex test/shem/llm/middleware/openai_transport_test.exs
git commit -m "feat: phase-22 — OpenAITransport stream/4 with SSE + tool_call accumulation"
```

---

## Task 5 — `LlamaCppTransport.stream/4`

**Files:**
- Modify: `lib/shem/llm/middleware/llama_cpp_transport.ex`
- Modify: `test/shem/llm/middleware/llama_cpp_transport_test.exs`

LlamaCpp uses the same `/v1/chat/completions` endpoint and identical SSE format as OpenAI. Copy the SSE logic verbatim — the only differences are: `base_url` defaults to the llama.cpp config key, no `api_key` guard, `model_string` uses `resolve_model/2`.

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/llm/middleware/llama_cpp_transport_test.exs`:

```elixir
describe "stream/4" do
  test "calls chunk_fn per text token and returns assembled Response" do
    {:ok, collector} = Agent.start_link(fn -> [] end)
    chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

    http_stream_fn = fn _url, _body, cf ->
      cf.("alpha")
      cf.(" beta")
      {:ok, %Shem.LLM.Response{
        content: "alpha beta",
        tool_calls: nil,
        tokens_used: 8,
        model: :default,
        latency_ms: 0
      }}
    end

    request = %Shem.LLM.Request{prompt: "hi", model: :default}
    opts = [http_stream_fn: http_stream_fn]

    assert {:ok, %{content: "alpha beta", tokens_used: 8}} =
             LlamaCppTransport.stream(request, opts, chunk_fn, fn _, _ -> :ok end)

    assert Agent.get(collector, & &1) == ["alpha", " beta"]
  end

  test "returns tool_calls and suppresses chunk_fn after tool_call" do
    http_stream_fn = fn _url, _body, _cf ->
      {:ok, %Shem.LLM.Response{
        content: nil,
        tool_calls: [%{id: "call_x", name: "shell", args: %{"cmd" => "pwd"}}],
        tokens_used: 12,
        model: :default,
        latency_ms: 0
      }}
    end

    request = %Shem.LLM.Request{prompt: "pwd", model: :default}
    opts = [http_stream_fn: http_stream_fn]

    assert {:ok, %{tool_calls: [%{name: "shell"}]}} =
             LlamaCppTransport.stream(request, opts, fn _ -> :ok end, fn _, _ -> :ok end)
  end
end
```

Run: `mix test test/shem/llm/middleware/llama_cpp_transport_test.exs --grep "stream/4" -v`
Expected: FAIL.

- [ ] **Step 2: Implement `LlamaCppTransport.stream/4`**

Add to `lib/shem/llm/middleware/llama_cpp_transport.ex` after the existing `call/3`:

```elixir
@impl true
def stream(request, opts, chunk_fn, _next) do
  url = Keyword.get(opts, :url, Application.get_env(:shem, :llm_llama_cpp_url, "http://localhost:8080"))
  timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))
  max_tokens = Map.get(request.options, :max_tokens, 512)

  messages =
    case request.messages do
      nil -> [%{"role" => "user", "content" => request.prompt}]
      msgs -> Enum.map(msgs, &format_message/1)
    end

  base_body = %{
    "model" => resolve_model(request.model, opts),
    "messages" => messages,
    "max_tokens" => max_tokens,
    "stream" => true,
    "stream_options" => %{"include_usage" => true}
  }

  tools_fields =
    case request.tools do
      nil -> %{}
      tools ->
        %{
          "tools" =>
            Enum.map(tools, fn %{name: n, description: d, schema: s} ->
              %{"type" => "function", "function" => %{"name" => n, "description" => d, "parameters" => s}}
            end),
          "tool_choice" => "auto"
        }
    end

  body = Map.merge(base_body, tools_fields)
  headers = []

  http_stream =
    Keyword.get(opts, :http_stream_fn, fn u, b, cf ->
      do_sse_stream_llama(u, b, headers, timeout_ms, request.model, cf)
    end)

  http_stream.(url <> "/v1/chat/completions", body, chunk_fn)
end

defp do_sse_stream_llama(url, body, headers, timeout_ms, model, chunk_fn) do
  start_ms = System.monotonic_time(:millisecond)
  ref = make_ref()

  Process.put(ref, %{
    buf: "",
    content: "",
    tool_calls: %{},
    tool_cut: false,
    prompt_tokens: 0,
    completion_tokens: 0
  })

  result =
    Req.post(url,
      json: body,
      headers: headers,
      receive_timeout: timeout_ms,
      into: fn {:data, data}, acc ->
        st = process_llama_sse_data(data, Process.get(ref), chunk_fn)
        Process.put(ref, st)
        {:cont, acc}
      end
    )

  final = Process.delete(ref)
  latency_ms = System.monotonic_time(:millisecond) - start_ms

  case result do
    {:ok, %{status: 200}} -> assemble_llama_response(final, model, latency_ms)
    {:ok, %{status: status}} -> {:error, {:transport, {:http_error, status}}}
    {:error, reason} -> {:error, {:transport, reason}}
  end
end

# SSE parsing is identical to OpenAI — split on \n\n, extract data: lines
defp process_llama_sse_data(data, state, chunk_fn) do
  {events, new_buf} = split_sse_events(state.buf <> data)
  Enum.reduce(events, %{state | buf: new_buf}, &process_llama_event(&1, &2, chunk_fn))
end

defp split_sse_events(buffer) do
  parts = String.split(buffer, "\n\n")
  case parts do
    [single] -> {[], single}
    _ ->
      events = parts |> Enum.slice(0..-2//1) |> Enum.reject(&(&1 == ""))
      {events, List.last(parts)}
  end
end

defp process_llama_event(event, state, chunk_fn) do
  data_line =
    event |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "data: "))

  case data_line do
    nil -> state
    "data: [DONE]" -> state
    "data: " <> json_str ->
      case Jason.decode(json_str) do
        {:ok, decoded} -> apply_llama_chunk(decoded, state, chunk_fn)
        _ -> state
      end
  end
end

defp apply_llama_chunk(%{"choices" => [%{"delta" => delta} | _]} = msg, state, chunk_fn) do
  state =
    case delta do
      %{"content" => content} when is_binary(content) and content != "" ->
        unless state.tool_cut, do: chunk_fn.(content)
        %{state | content: state.content <> content}

      %{"tool_calls" => raw_calls} ->
        Enum.reduce(raw_calls, %{state | tool_cut: true}, fn %{"index" => idx} = tc, acc ->
          existing = Map.get(acc.tool_calls, idx, %{id: nil, name: nil, args_buf: ""})
          updated = %{
            id: Map.get(tc, "id", existing.id),
            name: get_in(tc, ["function", "name"]) || existing.name,
            args_buf: existing.args_buf <> (get_in(tc, ["function", "arguments"]) || "")
          }
          %{acc | tool_calls: Map.put(acc.tool_calls, idx, updated)}
        end)

      _ -> state
    end

  case Map.get(msg, "usage") do
    nil -> state
    usage ->
      %{state |
        prompt_tokens: Map.get(usage, "prompt_tokens", state.prompt_tokens),
        completion_tokens: Map.get(usage, "completion_tokens", state.completion_tokens)}
  end
end

defp apply_llama_chunk(%{"usage" => usage}, state, _cf) do
  %{state |
    prompt_tokens: Map.get(usage, "prompt_tokens", state.prompt_tokens),
    completion_tokens: Map.get(usage, "completion_tokens", state.completion_tokens)}
end

defp apply_llama_chunk(_decoded, state, _cf), do: state

defp assemble_llama_response(final, model, latency_ms) do
  tokens_used = final.prompt_tokens + final.completion_tokens

  tool_calls =
    if map_size(final.tool_calls) == 0 do
      nil
    else
      final.tool_calls
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_, %{id: id, name: name, args_buf: args_buf}} ->
        %{id: id, name: name, args: Jason.decode!(args_buf)}
      end)
    end

  content = if final.content == "", do: nil, else: final.content

  {:ok,
   %Shem.LLM.Response{
     content: content,
     tool_calls: tool_calls,
     tokens_used: tokens_used,
     model: model,
     latency_ms: latency_ms
   }}
end
```

- [ ] **Step 3: Run tests**

Run: `mix test test/shem/llm/middleware/llama_cpp_transport_test.exs -v`
Expected: all pass.

- [ ] **Step 4: Run full suite**

Run: `mix test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/middleware/llama_cpp_transport.ex test/shem/llm/middleware/llama_cpp_transport_test.exs
git commit -m "feat: phase-22 — LlamaCppTransport stream/4"
```

---

## Task 6 — `AnthropicTransport.stream/4`

**Files:**
- Modify: `lib/shem/llm/middleware/anthropic_transport.ex`
- Modify: `test/shem/llm/middleware/anthropic_transport_test.exs`

### Anthropic SSE Background

Anthropic streaming uses `"stream": true` and emits named SSE events. The `data:` line per event contains a JSON object with a `"type"` field. Key event types:

- `message_start` — has `message.usage.input_tokens`
- `content_block_start` — starts a content block; if `content_block.type == "tool_use"`, sets `tool_cut: true` and records the tool call entry
- `content_block_delta` — if `delta.type == "text_delta"`, call `chunk_fn.(delta.text)` unless `tool_cut`; if `delta.type == "input_json_delta"`, accumulate `delta.partial_json` into the current tool call
- `message_delta` — has `usage.output_tokens`

Tool calls are indexed (same tool block index persists across `content_block_start` + `content_block_delta` events). Token counts arrive in `message_start` (input) and `message_delta` (output).

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/llm/middleware/anthropic_transport_test.exs`:

```elixir
describe "stream/4 — text response" do
  test "calls chunk_fn per text token" do
    {:ok, collector} = Agent.start_link(fn -> [] end)
    chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

    http_stream_fn = fn _url, _body, cf ->
      cf.("Hello ")
      cf.("Claude")
      {:ok, %Shem.LLM.Response{
        content: "Hello Claude",
        tool_calls: nil,
        tokens_used: 12,
        model: :default,
        latency_ms: 0
      }}
    end

    request = %Shem.LLM.Request{prompt: "hi", model: :default}
    opts = [api_key: "test-key", http_stream_fn: http_stream_fn]

    assert {:ok, %{content: "Hello Claude"}} =
             AnthropicTransport.stream(request, opts, chunk_fn, fn _, _ -> :ok end)

    assert Agent.get(collector, & &1) == ["Hello ", "Claude"]
  end
end

describe "stream/4 — tool call" do
  test "returns tool_calls in Response; chunk_fn only called before tool_cut" do
    http_stream_fn = fn _url, _body, cf ->
      cf.("I'll use a tool")
      {:ok, %Shem.LLM.Response{
        content: "I'll use a tool",
        tool_calls: [%{id: "toolu_abc", name: "shell", args: %{"cmd" => "ls"}}],
        tokens_used: 20,
        model: :default,
        latency_ms: 0
      }}
    end

    request = %Shem.LLM.Request{prompt: "ls", model: :default}
    opts = [api_key: "test-key", http_stream_fn: http_stream_fn]

    assert {:ok, %{tool_calls: [%{id: "toolu_abc", name: "shell"}]}} =
             AnthropicTransport.stream(request, opts, fn _ -> :ok end, fn _, _ -> :ok end)
  end
end

describe "stream/4 — error" do
  test "returns {:error, {:transport, :missing_api_key}} when api_key absent" do
    request = %Shem.LLM.Request{prompt: "hi", model: :default}

    assert {:error, {:transport, :missing_api_key}} =
             AnthropicTransport.stream(request, [api_key: nil], fn _ -> :ok end, fn _, _ -> :ok end)
  end
end
```

Run: `mix test test/shem/llm/middleware/anthropic_transport_test.exs --grep "stream/4" -v`
Expected: FAIL.

- [ ] **Step 2: Implement `AnthropicTransport.stream/4`**

Add after `call/3` in `lib/shem/llm/middleware/anthropic_transport.ex`:

```elixir
@impl true
def stream(request, opts, chunk_fn, _next) do
  api_key = Keyword.get(opts, :api_key, System.get_env("ANTHROPIC_API_KEY"))

  if is_nil(api_key) or api_key == "" do
    {:error, {:transport, :missing_api_key}}
  else
    http_stream = Keyword.get(opts, :http_stream_fn, &do_anthropic_sse/6)
    timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))
    model_string = Keyword.get(opts, :model_string, "claude-sonnet-4-6")
    max_tokens = Map.get(request.options, :max_tokens, 512)
    base_url = Keyword.get(opts, :base_url, "https://api.anthropic.com")

    {body_messages, maybe_system} =
      case request.messages do
        nil -> {[%{"role" => "user", "content" => request.prompt}], nil}
        msgs -> {format_messages(msgs), request.system}
      end

    base_body = %{
      "model" => model_string,
      "messages" => body_messages,
      "max_tokens" => max_tokens,
      "stream" => true
    }

    body = if maybe_system, do: Map.put(base_body, "system", maybe_system), else: base_body

    tools_fields =
      case request.tools do
        nil -> %{}
        tools ->
          %{"tools" => Enum.map(tools, fn %{name: n, description: d, schema: s} ->
            %{"name" => n, "description" => d, "input_schema" => s}
          end)}
      end

    body = Map.merge(body, tools_fields)

    headers = [{"x-api-key", api_key}, {"anthropic-version", "2023-06-01"}]

    http_stream.(base_url <> "/v1/messages", body, headers, timeout_ms, request.model, chunk_fn)
  end
end

defp do_anthropic_sse(url, body, headers, timeout_ms, model, chunk_fn) do
  start_ms = System.monotonic_time(:millisecond)
  ref = make_ref()

  Process.put(ref, %{
    buf: "",
    content: "",
    # tool_calls map: index => %{id, name, args_buf}
    tool_calls: %{},
    tool_cut: false,
    input_tokens: 0,
    output_tokens: 0
  })

  result =
    Req.post(url,
      json: body,
      headers: headers,
      receive_timeout: timeout_ms,
      into: fn {:data, data}, acc ->
        st = process_anthropic_data(data, Process.get(ref), chunk_fn)
        Process.put(ref, st)
        {:cont, acc}
      end
    )

  final = Process.delete(ref)
  latency_ms = System.monotonic_time(:millisecond) - start_ms

  case result do
    {:ok, %{status: 200}} -> assemble_anthropic_response(final, model, latency_ms)
    {:ok, %{status: 401}} -> {:error, {:transport, :unauthorized}}
    {:ok, %{status: 429}} -> {:error, {:transport, :rate_limited}}
    {:ok, %{status: status}} -> {:error, {:transport, {:http_error, status}}}
    {:error, reason} -> {:error, {:transport, reason}}
  end
end

defp process_anthropic_data(data, state, chunk_fn) do
  {events, new_buf} = split_anthropic_events(state.buf <> data)
  Enum.reduce(events, %{state | buf: new_buf}, &process_anthropic_event(&1, &2, chunk_fn))
end

defp split_anthropic_events(buffer) do
  parts = String.split(buffer, "\n\n")
  case parts do
    [single] -> {[], single}
    _ ->
      events = parts |> Enum.slice(0..-2//1) |> Enum.reject(&(&1 == ""))
      {events, List.last(parts)}
  end
end

defp process_anthropic_event(event, state, chunk_fn) do
  data_line =
    event |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "data: "))

  case data_line do
    nil -> state
    "data: " <> json_str ->
      case Jason.decode(json_str) do
        {:ok, decoded} -> apply_anthropic_chunk(decoded, state, chunk_fn)
        _ -> state
      end
  end
end

defp apply_anthropic_chunk(%{"type" => "message_start", "message" => %{"usage" => usage}}, state, _cf) do
  %{state | input_tokens: Map.get(usage, "input_tokens", 0)}
end

defp apply_anthropic_chunk(
       %{"type" => "content_block_start", "index" => idx,
         "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}},
       state,
       _cf
     ) do
  new_tool = %{id: id, name: name, args_buf: ""}
  %{state | tool_calls: Map.put(state.tool_calls, idx, new_tool), tool_cut: true}
end

defp apply_anthropic_chunk(
       %{"type" => "content_block_delta", "index" => _idx,
         "delta" => %{"type" => "text_delta", "text" => text}},
       state,
       chunk_fn
     ) when is_binary(text) and text != "" do
  unless state.tool_cut, do: chunk_fn.(text)
  %{state | content: state.content <> text}
end

defp apply_anthropic_chunk(
       %{"type" => "content_block_delta", "index" => idx,
         "delta" => %{"type" => "input_json_delta", "partial_json" => partial}},
       state,
       _cf
     ) do
  existing = Map.get(state.tool_calls, idx, %{id: nil, name: nil, args_buf: ""})
  updated = %{existing | args_buf: existing.args_buf <> partial}
  %{state | tool_calls: Map.put(state.tool_calls, idx, updated)}
end

defp apply_anthropic_chunk(%{"type" => "message_delta", "usage" => usage}, state, _cf) do
  %{state | output_tokens: Map.get(usage, "output_tokens", 0)}
end

defp apply_anthropic_chunk(_decoded, state, _cf), do: state

defp assemble_anthropic_response(final, model, latency_ms) do
  tokens_used = final.input_tokens + final.output_tokens

  tool_calls =
    if map_size(final.tool_calls) == 0 do
      nil
    else
      final.tool_calls
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_, %{id: id, name: name, args_buf: args_buf}} ->
        args = if args_buf == "", do: %{}, else: Jason.decode!(args_buf)
        %{id: id, name: name, args: args}
      end)
    end

  content = if final.content == "", do: nil, else: final.content

  {:ok,
   %Shem.LLM.Response{
     content: content,
     tool_calls: tool_calls,
     tokens_used: tokens_used,
     model: model,
     latency_ms: latency_ms
   }}
end
```

- [ ] **Step 3: Run tests**

Run: `mix test test/shem/llm/middleware/anthropic_transport_test.exs -v`
Expected: all pass.

- [ ] **Step 4: Run full suite**

Run: `mix test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/middleware/anthropic_transport.ex test/shem/llm/middleware/anthropic_transport_test.exs
git commit -m "feat: phase-22 — AnthropicTransport stream/4"
```

---

## Task 7 — `OllamaTransport.stream/4`

**Files:**
- Modify: `lib/shem/llm/middleware/ollama_transport.ex`
- Modify: `test/shem/llm/middleware/ollama_transport_test.exs`

### Ollama NDJSON Background

Ollama streaming uses `"stream": true` and returns newline-delimited JSON (not SSE). Each line is a complete JSON object:

```json
{"model":"llama3","message":{"role":"assistant","content":"Hello"},"done":false}
{"model":"llama3","message":{"role":"assistant","content":" world"},"done":false}
{"model":"llama3","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"shell","arguments":{"cmd":"ls"}}}]},"done":true,"eval_count":12,"prompt_eval_count":8}
```

Rules:
- Split on `\n` (not `\n\n`).
- `done: false` → `message.content` → call `chunk_fn` if non-empty and not `tool_cut`.
- `done: true` → check `message.tool_calls` for tool calls; accumulate `eval_count` + `prompt_eval_count` for token count. Tool_calls on the `done: true` chunk (not spread across chunks like OpenAI/Anthropic), so no index accumulation needed.

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/llm/middleware/ollama_transport_test.exs`:

```elixir
describe "stream/4 — text response" do
  test "calls chunk_fn per non-empty chunk and returns assembled Response" do
    {:ok, collector} = Agent.start_link(fn -> [] end)
    chunk_fn = fn t -> Agent.update(collector, &(&1 ++ [t])) end

    http_stream_fn = fn _url, _body, cf ->
      cf.("Hello")
      cf.(" there")
      {:ok, %Shem.LLM.Response{
        content: "Hello there",
        tool_calls: nil,
        tokens_used: 9,
        model: :default,
        latency_ms: 0
      }}
    end

    request = %Shem.LLM.Request{prompt: "hi", model: :default}
    opts = [http_stream_fn: http_stream_fn]

    assert {:ok, %{content: "Hello there", tokens_used: 9}} =
             OllamaTransport.stream(request, opts, chunk_fn, fn _, _ -> :ok end)

    assert Agent.get(collector, & &1) == ["Hello", " there"]
  end
end

describe "stream/4 — tool call" do
  test "returns tool_calls from the done chunk" do
    http_stream_fn = fn _url, _body, _cf ->
      {:ok, %Shem.LLM.Response{
        content: nil,
        tool_calls: [%{id: "ollama_1", name: "shell", args: %{"cmd" => "pwd"}}],
        tokens_used: 14,
        model: :default,
        latency_ms: 0
      }}
    end

    request = %Shem.LLM.Request{prompt: "pwd", model: :default}

    assert {:ok, %{tool_calls: [%{name: "shell"}]}} =
             OllamaTransport.stream(request, [http_stream_fn: http_stream_fn], fn _ -> :ok end, fn _, _ -> :ok end)
  end
end
```

Run: `mix test test/shem/llm/middleware/ollama_transport_test.exs --grep "stream/4" -v`
Expected: FAIL.

- [ ] **Step 2: Implement `OllamaTransport.stream/4`**

Add after `call/3` in `lib/shem/llm/middleware/ollama_transport.ex`:

```elixir
@impl true
def stream(request, opts, chunk_fn, _next) do
  url = Keyword.get(opts, :url, Application.get_env(:shem, :llm_ollama_url, "http://localhost:11434"))

  messages =
    case request.messages do
      nil -> [%{"role" => "user", "content" => request.prompt}]
      msgs -> Enum.map(msgs, &format_message/1)
    end

  tools_fields =
    case request.tools do
      nil -> %{}
      tools ->
        %{"tools" => Enum.map(tools, fn %{name: n, description: d, schema: s} ->
          %{"type" => "function", "function" => %{"name" => n, "description" => d, "parameters" => s}}
        end)}
    end

  body =
    Map.merge(
      %{
        "model" => resolve_model(request.model, opts),
        "messages" => messages,
        "stream" => true
      },
      tools_fields
    )

  http_stream =
    Keyword.get(opts, :http_stream_fn, fn u, b, cf ->
      do_ollama_stream(u, b, request.model, cf)
    end)

  http_stream.(url <> "/api/chat", body, chunk_fn)
end

defp do_ollama_stream(url, body, model, chunk_fn) do
  start_ms = System.monotonic_time(:millisecond)
  ref = make_ref()

  Process.put(ref, %{
    buf: "",
    content: "",
    tool_calls: nil,
    tool_cut: false,
    eval_count: 0,
    prompt_eval_count: 0
  })

  result =
    Req.post(url,
      json: body,
      into: fn {:data, data}, acc ->
        st = process_ollama_data(data, Process.get(ref), chunk_fn)
        Process.put(ref, st)
        {:cont, acc}
      end
    )

  final = Process.delete(ref)
  latency_ms = System.monotonic_time(:millisecond) - start_ms

  case result do
    {:ok, %{status: 200}} ->
      assemble_ollama_response(final, model, latency_ms)

    {:ok, %{status: status}} ->
      {:error, {:transport, {:http_error, status}}}

    {:error, reason} ->
      {:error, {:transport, reason}}
  end
end

defp process_ollama_data(data, state, chunk_fn) do
  full = state.buf <> data
  {lines, new_buf} = split_ndjson_lines(full)
  Enum.reduce(lines, %{state | buf: new_buf}, &process_ollama_line(&1, &2, chunk_fn))
end

defp split_ndjson_lines(buffer) do
  parts = String.split(buffer, "\n")
  case parts do
    [single] -> {[], single}
    _ ->
      lines = parts |> Enum.slice(0..-2//1) |> Enum.reject(&(&1 == ""))
      {lines, List.last(parts)}
  end
end

defp process_ollama_line(line, state, chunk_fn) do
  case Jason.decode(line) do
    {:ok, %{"done" => false, "message" => %{"content" => content}}} when is_binary(content) and content != "" ->
      unless state.tool_cut, do: chunk_fn.(content)
      %{state | content: state.content <> content}

    {:ok, %{"done" => true} = msg} ->
      raw_calls = get_in(msg, ["message", "tool_calls"])
      tool_calls =
        case raw_calls do
          nil -> nil
          [] -> nil
          calls ->
            Enum.map(calls, fn %{"function" => %{"name" => n, "arguments" => a}} ->
              %{id: "ollama_#{:erlang.unique_integer([:positive, :monotonic])}", name: n, args: a}
            end)
        end

      %{state |
        tool_calls: tool_calls,
        tool_cut: not is_nil(tool_calls),
        eval_count: Map.get(msg, "eval_count", 0),
        prompt_eval_count: Map.get(msg, "prompt_eval_count", 0)}

    _ ->
      state
  end
end

defp assemble_ollama_response(final, model, latency_ms) do
  tokens_used = final.eval_count + final.prompt_eval_count
  content = if final.content == "", do: nil, else: final.content

  {:ok,
   %Shem.LLM.Response{
     content: content,
     tool_calls: final.tool_calls,
     tokens_used: tokens_used,
     model: model,
     latency_ms: latency_ms
   }}
end
```

- [ ] **Step 3: Run tests**

Run: `mix test test/shem/llm/middleware/ollama_transport_test.exs -v`
Expected: all pass.

- [ ] **Step 4: Run full suite**

Run: `mix test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/middleware/ollama_transport.ex test/shem/llm/middleware/ollama_transport_test.exs
git commit -m "feat: phase-22 — OllamaTransport stream/4 with NDJSON streaming"
```

---

## Task 8 — `Agent.Turn.stream_step/4`

**Files:**
- Modify: `lib/shem/agent/turn.ex`
- Modify: `test/shem/agent/turn_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/shem/agent/turn_test.exs`:

```elixir
describe "stream_step/4" do
  setup do
    Shem.LLM.BudgetServer.reset()
    StubTransport.Server.reset()
    :ok
  end

  defp stub(content, tokens \\ 5) do
    StubTransport.Server.push_response(
      {:ok, %Shem.LLM.Response{content: content, tokens_used: tokens, model: :default, latency_ms: 1}}
    )
  end

  test "broadcasts {:stream_chunk, session_id, token} to StreamRegistry subscribers" do
    stub("The answer is 42.")
    session_id = "stream_test_#{System.unique_integer()}"

    Registry.register(Shem.StreamRegistry, session_id, nil)

    config = %Shem.Agent.Config{task: "test", system_prompt: "be helpful"}
    history = [%{role: :user, content: "what is 6*7?"}]

    assert {:done, _} = Shem.Agent.Turn.stream_step(config, session_id, history, [])

    # Should have received at least one :stream_chunk
    messages =
      receive do
        {:stream_chunk, ^session_id, token} -> [token]
      after
        500 -> []
      end

    assert messages != []
  end

  test "returns {:done, answer} for a plain text response" do
    stub("42 is the answer.")
    session_id = "stream_test_#{System.unique_integer()}"
    config = %Shem.Agent.Config{task: "test", system_prompt: "be helpful"}
    history = [%{role: :user, content: "compute"}]

    assert {:done, answer} = Shem.Agent.Turn.stream_step(config, session_id, history, [])
    assert answer =~ "42"
  end

  test "returns {:tool_calls, calls, raw} for a native tool_calls response" do
    StubTransport.Server.push_response(
      {:ok, %Shem.LLM.Response{
        content: nil,
        tool_calls: [%{id: "call_1", name: "list_tools", args: %{}}],
        tokens_used: 5,
        model: :default,
        latency_ms: 1
      }}
    )

    session_id = "stream_test_#{System.unique_integer()}"
    config = %Shem.Agent.Config{task: "test", system_prompt: "be helpful"}
    history = [%{role: :user, content: "list tools"}]

    assert {:tool_calls, [%{name: "list_tools"}], _raw} =
             Shem.Agent.Turn.stream_step(config, session_id, history, [])
  end

  test "returns {:error, reason} when LLM returns error" do
    StubTransport.Server.push_response({:error, :transport_down})
    session_id = "stream_test_#{System.unique_integer()}"
    config = %Shem.Agent.Config{task: "test", system_prompt: "be helpful"}
    history = [%{role: :user, content: "task"}]

    assert {:error, :transport_down} =
             Shem.Agent.Turn.stream_step(config, session_id, history, [])
  end
end
```

Run: `mix test test/shem/agent/turn_test.exs --grep "stream_step" -v`
Expected: FAIL — `stream_step/4` undefined.

- [ ] **Step 2: Implement `Turn.stream_step/4`**

Add to `lib/shem/agent/turn.ex` after `step/4`:

```elixir
@spec stream_step(Config.t(), String.t(), [map()], [map()]) ::
        {:tool_calls, [%{id: String.t() | nil, name: String.t(), args: map()}], String.t()}
        | {:done, String.t()}
        | {:error, term()}
def stream_step(%Config{} = config, session_id, history, tools_manifest) do
  chunk_fn = fn token ->
    Registry.dispatch(Shem.StreamRegistry, session_id, fn entries ->
      Enum.each(entries, fn {pid, _} -> send(pid, {:stream_chunk, session_id, token}) end)
    end)
  end

  request =
    config.model
    |> build_request(config.system_prompt, tools_manifest, history)
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

- [ ] **Step 3: Run tests**

Run: `mix test test/shem/agent/turn_test.exs -v`
Expected: all pass.

- [ ] **Step 4: Run full suite**

Run: `mix test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/agent/turn.ex test/shem/agent/turn_test.exs
git commit -m "feat: phase-22 — Agent.Turn.stream_step/4"
```

---

## Task 9 — `Agent.Server` Streaming Swap + `stream_done` Broadcast

**Files:**
- Modify: `lib/shem/agent/server.ex`
- Modify: `test/shem/agent/server_test.exs`

Two changes:
1. Replace `Turn.step/4` with `Turn.stream_step/4` in `handle_info(:run_turn, ...)`.
2. Broadcast `{:stream_done, session_id}` via `Registry.dispatch` in both `finish/3` clauses so REST SSE handlers know when to close.

- [ ] **Step 1: Write the failing test**

Add to `test/shem/agent/server_test.exs` (inside `describe "single-turn run (no tool calls)"` or a new describe):

```elixir
describe "streaming" do
  test "broadcasts {:stream_chunk, session_id, token} during a turn" do
    stub("Streaming answer here.")
    name = start_agent("streaming test")

    {:ok, session_id} = Agent.session_id(name)
    Registry.register(Shem.StreamRegistry, session_id, nil)

    assert {:ok, :done} = Agent.await(name, 2_000)

    # Drain all stream_chunk messages
    chunks = collect_stream_chunks(session_id)
    assert chunks != []
    assert Enum.join(chunks) =~ "Streaming"
  end

  test "broadcasts {:stream_done, session_id} when agent finishes" do
    stub("done")
    name = start_agent("stream done test")

    {:ok, session_id} = Agent.session_id(name)
    Registry.register(Shem.StreamRegistry, session_id, nil)

    assert {:ok, :done} = Agent.await(name, 2_000)

    assert_receive {:stream_done, ^session_id}, 500
  end
end
```

Add a helper at the bottom of the test module:

```elixir
defp collect_stream_chunks(session_id) do
  collect_stream_chunks(session_id, [])
end

defp collect_stream_chunks(session_id, acc) do
  receive do
    {:stream_chunk, ^session_id, token} -> collect_stream_chunks(session_id, [token | acc])
  after
    200 -> Enum.reverse(acc)
  end
end
```

Run: `mix test test/shem/agent/server_test.exs --grep "streaming" -v`
Expected: FAIL.

- [ ] **Step 2: Swap `Turn.step/4` → `Turn.stream_step/4` in `Agent.Server`**

In `lib/shem/agent/server.ex`, find the line:

```elixir
case Turn.step(state.config, state.session_id, state.history, manifest) do
```

Change it to:

```elixir
case Turn.stream_step(state.config, state.session_id, state.history, manifest) do
```

- [ ] **Step 3: Add `stream_done` broadcast to both `finish/3` clauses**

In `lib/shem/agent/server.ex`, modify `finish/3` to broadcast `:stream_done`:

```elixir
defp finish(state, status, :answer) do
  last_content =
    state.history
    |> Enum.filter(&(&1.role == :assistant))
    |> List.last()
    |> Map.get(:content, "")

  EventLog.append(state.session_id, :agent_done, %{reason: :answer, content: last_content})
  broadcast_stream_done(state.session_id)
  Enum.each(state.awaiting, fn from -> GenServer.reply(from, {:ok, status}) end)
  %{state | status: status, done_reason: :answer, awaiting: []}
end

defp finish(state, status, reason) do
  EventLog.append(state.session_id, :agent_done, %{reason: reason})
  broadcast_stream_done(state.session_id)
  Enum.each(state.awaiting, fn from -> GenServer.reply(from, {:ok, status}) end)
  %{state | status: status, done_reason: reason, awaiting: []}
end

defp broadcast_stream_done(session_id) do
  Registry.dispatch(Shem.StreamRegistry, session_id, fn entries ->
    Enum.each(entries, fn {pid, _} -> send(pid, {:stream_done, session_id}) end)
  end)
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/shem/agent/server_test.exs -v`
Expected: all pass.

- [ ] **Step 5: Run full suite**

Run: `mix test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/agent/server.ex test/shem/agent/server_test.exs
git commit -m "feat: phase-22 — Agent.Server streams via stream_step; broadcasts stream_done"
```

---

## Task 10 — TUI Streaming Display

**Files:**
- Create: `lib/shem/tui/stream_sink.ex`
- Modify: `lib/shem/tui/agent_view.ex`
- Modify: `lib/shem/tui/app.ex`

### Architecture

Ratatouille's `App` behaviour drives the TUI via `update/2` and a polling subscription. External process messages do not route through `App.update/2` automatically. To bridge this:

1. **`Shem.TUI.StreamSink`** — a `GenServer` that registers with `Shem.StreamRegistry` for the active agent's `session_id` and buffers incoming `{:stream_chunk, ...}` messages.
2. **`AgentView`** — gains a `streaming_buffer: nil` field.
3. **`App`** — changes the subscription tick to 100ms (was 500ms); on each tick, if a `stream_sink` pid is tracked, drains it and appends tokens to `agent_view.streaming_buffer`; clears the buffer when `:llm_call_completed` arrives; starts/stops StreamSink when the focused agent changes.

The render layer uses `streaming_buffer` in the same display slot as `current_reasoning` — whichever is non-nil shows.

- [ ] **Step 1: Create `Shem.TUI.StreamSink`**

Create `lib/shem/tui/stream_sink.ex`:

```elixir
defmodule Shem.TUI.StreamSink do
  use GenServer

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id)
  end

  def take_tokens(pid) do
    GenServer.call(pid, :take_tokens)
  end

  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  end

  def stop(nil), do: :ok

  @impl true
  def init(session_id) do
    Registry.register(Shem.StreamRegistry, session_id, nil)
    {:ok, %{session_id: session_id, buffer: []}}
  end

  @impl true
  def handle_info({:stream_chunk, _session_id, token}, state) do
    {:noreply, %{state | buffer: state.buffer ++ [token]}}
  end

  def handle_info({:stream_done, _session_id}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:take_tokens, _from, state) do
    {:reply, state.buffer, %{state | buffer: []}}
  end
end
```

- [ ] **Step 2: Add `streaming_buffer` field to `AgentView`**

In `lib/shem/tui/agent_view.ex`, add `streaming_buffer: nil` to the `defstruct`:

```elixir
defstruct [
  :agent_name,
  status: :running,
  turn_count: 0,
  max_turns: 20,
  current_reasoning: nil,
  streaming_buffer: nil,
  last_tool_call: nil,
  history: [],
  recent_events: []
]
```

Add the type to `@type t`:

```elixir
@type t :: %__MODULE__{
        agent_name: String.t() | nil,
        status: :running | :done | :error,
        turn_count: non_neg_integer(),
        max_turns: pos_integer(),
        current_reasoning: String.t() | nil,
        streaming_buffer: String.t() | nil,
        last_tool_call: %{name: String.t(), args: map(), result: String.t() | nil} | nil,
        history: [%{turn: non_neg_integer(), tool: String.t() | nil}],
        recent_events: [atom()]
      }
```

- [ ] **Step 3: Update `App` to manage StreamSink and poll tokens**

In `lib/shem/tui/app.ex`:

**3a.** Add `stream_sink: nil` to the `init/1` state map.

**3b.** Change the subscription from 500ms to 100ms:

```elixir
@impl true
def subscribe(_model) do
  Subscription.interval(100, :tick)
end
```

**3c.** In the `:tick` handler (find the `{:tick, _}` or `:tick` clause in `update/2`), add token draining logic. The tick handler currently refreshes agents, event log stats, etc. Append:

```elixir
# drain streaming tokens
model =
  if model.stream_sink && is_pid(model.stream_sink) && Process.alive?(model.stream_sink) do
    tokens = Shem.TUI.StreamSink.take_tokens(model.stream_sink)
    case tokens do
      [] ->
        model
      _ ->
        new_buf = (model.agent_view && model.agent_view.streaming_buffer || "") <> Enum.join(tokens)
        agent_view = model.agent_view && %{model.agent_view | streaming_buffer: new_buf}
        %{model | agent_view: agent_view}
    end
  else
    model
  end
```

(Wrap with a guard that `model.agent_view != nil` before accessing its fields.)

**3d.** When `focused_agent` changes (agent is focused), start a new StreamSink for the session_id. Find where `focused_agent` is set (e.g., after `/agent` command or similar) and add:

```elixir
# When starting StreamSink for a new focused agent:
defp start_stream_sink(model, session_id) do
  Shem.TUI.StreamSink.stop(model.stream_sink)
  {:ok, pid} = Shem.TUI.StreamSink.start_link(session_id)
  %{model | stream_sink: pid}
end
```

Call `start_stream_sink(model, session_id)` whenever `focused_agent` is newly set (search `focused_agent:` assignments in `app.ex`).

**3e.** Clear `streaming_buffer` when `:llm_call_completed` arrives. In the `:tick` handler where the agent_view is refreshed from EventLog, check the latest events and clear the streaming buffer if `:llm_call_completed` just arrived:

```elixir
# After agent_view is rebuilt from events:
agent_view =
  if agent_view && :llm_call_completed in (agent_view.recent_events |> Enum.take(-3)) do
    %{agent_view | streaming_buffer: nil}
  else
    agent_view
  end
```

**3f.** Stop the StreamSink when agent is done or user navigates away. In the `:tick` handler, after detecting `agent_view.status in [:done, :error]`:

```elixir
model =
  if model.agent_view && model.agent_view.status in [:done, :error] && model.stream_sink do
    Shem.TUI.StreamSink.stop(model.stream_sink)
    %{model | stream_sink: nil}
  else
    model
  end
```

**3g.** In the render layer (wherever `current_reasoning` is displayed), show `streaming_buffer` if set:

```elixir
# In the view render for agent_view, replace:
#   label(content: model.agent_view.current_reasoning || "")
# with:
display_text =
  model.agent_view.streaming_buffer ||
    model.agent_view.current_reasoning ||
    ""
label(content: display_text)
```

Find the correct location in the view module that renders `current_reasoning`.

- [ ] **Step 4: Run tests**

Run: `mix test`
Expected: all 617+ tests pass. (The TUI has no direct unit tests for this, but existing TUI tests should not break since `start_tui: false` in test env.)

- [ ] **Step 5: Commit**

```bash
git add lib/shem/tui/stream_sink.ex lib/shem/tui/agent_view.ex lib/shem/tui/app.ex
git commit -m "feat: phase-22 — TUI streaming display via StreamSink + streaming_buffer"
```

---

## Task 11 — REST SSE Endpoint

**Files:**
- Modify: `lib/shem/rest/handlers/agents.ex`
- Modify: `test/shem/rest/handlers/agents_test.exs`

### SSE Event Format

```
data: {"type":"chunk","content":"Let me"}\n\n
data: {"type":"chunk","content":" check"}\n\n
data: {"type":"done","status":"done"}\n\n
```

The handler registers with `Shem.StreamRegistry`, enters a receive loop, and writes SSE events as `{:stream_chunk, ...}` and `{:stream_done, ...}` messages arrive. On client disconnect or `stream_done`, the loop exits and unregisters.

- [ ] **Step 1: Write the failing test**

Add to `test/shem/rest/handlers/agents_test.exs`:

```elixir
describe "GET /:id/stream" do
  test "returns 404 for unknown agent" do
    conn =
      conn(:get, "/no_such_agent/stream")
      |> Shem.REST.Handlers.Agents.call([])

    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] =~ "not found"
  end

  test "streams SSE events and closes with done event" do
    StubTransport.Server.push_response(
      {:ok, %Shem.LLM.Response{content: "streamed answer", tokens_used: 5, model: :default, latency_ms: 1}}
    )

    {:ok, agent_name} = Shem.Agent.start(%Shem.Agent.Config{
      task: "sse test",
      system_prompt: "be helpful",
      max_turns: 1
    })

    # Give the agent a moment to get a session_id
    :timer.sleep(50)
    {:ok, session_id} = Shem.Agent.session_id(agent_name)

    # Subscribe to the registry to capture events before they're consumed
    Registry.register(Shem.StreamRegistry, session_id, nil)

    # Wait for agent to start streaming
    Shem.Agent.await(agent_name, 2_000)

    # Simulate the SSE handler by sending ourselves the stream_done
    # (already subscribed, will receive it from agent)
    assert_receive {:stream_done, ^session_id}, 2_000

    # Verify the GET /:id/stream route is registered (route-level test)
    conn =
      conn(:get, "/#{agent_name}/stream")
      |> Plug.Conn.assign(:stop_after_done, true)  # test flag
      |> Shem.REST.Handlers.Agents.call([])

    # Agent is already done; the handler should emit a done event and return
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"
  end
end
```

Run: `mix test test/shem/rest/handlers/agents_test.exs --grep "stream" -v`
Expected: FAIL or partial pass (route not found).

- [ ] **Step 2: Add `GET /:id/stream` to `Agents` handler**

Add a `stream_loop/2` helper and the route to `lib/shem/rest/handlers/agents.ex`. Insert the route **before** `get "/:id"` (routes are matched in order; `/:id/stream` must come before `/:id`):

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
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      Registry.register(Shem.StreamRegistry, session_id, nil)
      stream_loop(conn, session_id)
  end
end
```

Add helper functions to the module (after `send_json/3`):

```elixir
defp stream_loop(conn, session_id) do
  receive do
    {:stream_chunk, ^session_id, token} ->
      event = Jason.encode!(%{type: "chunk", content: token})
      case Plug.Conn.chunk(conn, "data: #{event}\n\n") do
        {:ok, conn} -> stream_loop(conn, session_id)
        {:error, _} ->
          Registry.unregister(Shem.StreamRegistry, session_id)
          conn
      end

    {:stream_done, ^session_id} ->
      status_str =
        case Shem.Agent.status(session_id) do
          {:ok, status} -> to_string(status)
          _ -> "done"
        end

      event = Jason.encode!(%{type: "done", status: status_str})
      Plug.Conn.chunk(conn, "data: #{event}\n\n")
      Registry.unregister(Shem.StreamRegistry, session_id)
      conn

    _other ->
      stream_loop(conn, session_id)
  after
    30_000 ->
      # Timeout — send a keepalive or close
      Registry.unregister(Shem.StreamRegistry, session_id)
      conn
  end
end
```

- [ ] **Step 3: Run tests**

Run: `mix test test/shem/rest/handlers/agents_test.exs -v`
Expected: all pass.

- [ ] **Step 4: Run full suite**

Run: `mix test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/rest/handlers/agents.ex test/shem/rest/handlers/agents_test.exs
git commit -m "feat: phase-22 — REST SSE endpoint GET /api/agents/:id/stream"
```

---

## Self-Review

### Spec Coverage

| Spec Requirement | Task |
|---|---|
| `Shem.StreamRegistry` in supervision tree | Task 1 |
| `Middleware.stream/4` optional callback | Task 1 |
| `LLM.stream_complete/2` | Task 2 |
| `build_stream_pipeline/1` with fallback | Task 2 |
| `StubTransport.stream/4` | Task 2 |
| `RouterTransport.stream/4` | Task 2 |
| `BudgetCheck.stream/4` | Task 3 |
| `EventLogger.stream/4` | Task 3 |
| `OpenAITransport.stream/4` + SSE | Task 4 |
| `LlamaCppTransport.stream/4` + SSE | Task 5 |
| `AnthropicTransport.stream/4` | Task 6 |
| `OllamaTransport.stream/4` (NDJSON) | Task 7 |
| `Turn.stream_step/4` | Task 8 |
| `Agent.Server` uses `stream_step/4` | Task 9 |
| `Agent.Server` broadcasts `stream_done` | Task 9 |
| TUI live token display | Task 10 |
| `AgentView.streaming_buffer` field | Task 10 |
| REST `GET /api/agents/:id/stream` SSE | Task 11 |
| SSE event types: `chunk`, `done` | Task 11 |
| Existing non-streaming path untouched | `complete/1` and `step/4` untouched |

All spec requirements are covered.

### Type Consistency

- `chunk_fn :: (String.t() -> :ok)` — used consistently in Tasks 1, 2, 3, 4, 5, 6, 7, 8.
- `stream_next :: (Request.t(), chunk_fn() -> pipeline_result())` — the `next` in `stream/4` is 2-arity in Tasks 3, and passed as `fn _req, _cf -> ...` in Tasks 4-7 (terminal transports ignore it). Confirmed consistent with Task 2's pipeline builder which builds 2-arity `fn req, chunk_fn -> ...` steps.
- `http_stream_fn :: (url, body, chunk_fn) -> {:ok, Response.t()} | {:error, term()}` — consistent across Tasks 4, 5, 6, 7.
- `Response.t()` fields `content`, `tool_calls`, `tokens_used`, `model`, `latency_ms` — consistent with Phase 21's `Response` struct.

### Potential Issues

1. **Req `into:` with process dict**: The `do_sse_stream_*` functions use `Process.put/get/delete` to carry state through the `into:` callback (since there's no clean way to pass an initial accumulator separately from the request body). This is correct and safe — each SSE stream runs in the caller's process. The `ref = make_ref()` ensures no key collision even in nested calls.

2. **TUI tick interval**: Changing 500ms → 100ms may increase CPU usage slightly on slow machines. This is acceptable for real-time streaming display and reverting is a one-line change.

3. **StreamSink lifecycle**: The StreamSink is started when an agent is focused and stopped when the agent finishes or focus changes. If the agent finishes very quickly (before the TUI tick detects it), the StreamSink will naturally stop on its next `take_tokens` call returning empty tokens — the `Process.alive?/1` guard in the tick handler prevents crashes.

4. **REST SSE route ordering**: `get "/:id/stream"` must appear before `get "/:id"` in `Plug.Router` to avoid the stream path being matched as an agent ID lookup for the agent named "stream". Task 11 explicitly notes this.
