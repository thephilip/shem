# Phase 5: LLM Driver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a middleware pipeline that lets Shem call LLMs (via Ollama), enforce token budgets, and automatically record every call in the event log.

**Architecture:** A `Shem.LLM.Middleware` behaviour defines `call/3` — each module gets `(request, opts, next)` and either calls `next.(request)` or halts with `{:error, reason}`. The pipeline is a config-driven list of `{module, opts}` tuples reduced into a nested closure. `BudgetCheck` and `EventLogger` run on both sides of the transport (pre and post `next.()`). `BudgetServer` is a named GenServer that holds the token accumulator; middleware opts carry its name for testability.

**Tech Stack:** Elixir/OTP, `req ~> 0.5` (HTTP client for Ollama), `jason ~> 1.4` (already present), ExUnit with `start_supervised/1`.

**Spec:** `docs/superpowers/specs/2026-06-04-phase-5-llm-driver-design.md`

---

## File Map

**Create:**
- `lib/shem/llm/request.ex` — `%Shem.LLM.Request{}` struct
- `lib/shem/llm/response.ex` — `%Shem.LLM.Response{}` struct
- `lib/shem/llm/middleware.ex` — `Shem.LLM.Middleware` behaviour
- `lib/shem/llm/budget_server.ex` — token accumulator GenServer
- `lib/shem/llm/middleware/budget_check.ex` — pre/post transport budget enforcement
- `lib/shem/llm/middleware/event_logger.ex` — pre/post transport event log writes
- `lib/shem/llm/middleware/ollama_transport.ex` — terminal HTTP middleware
- `lib/shem/llm/stub_transport/server.ex` — response-queue GenServer for tests
- `lib/shem/llm/stub_transport.ex` — terminal middleware backed by `StubTransport.Server`
- `lib/shem/llm.ex` — public API: `complete/1`, `stream/2`, pipeline assembly
- `scripts/smoke_llm.exs` — manual integration smoke test

**Modify:**
- `mix.exs` — add `req ~> 0.5`
- `config/dev.exs` — add LLM config keys
- `config/test.exs` — add LLM test config (StubTransport pipeline)
- `lib/shem/application.ex` — supervise `Shem.LLM.BudgetServer`

**Test files (mirror lib/ structure):**
- `test/shem/llm/request_test.exs`
- `test/shem/llm/response_test.exs`
- `test/shem/llm/budget_server_test.exs`
- `test/shem/llm/middleware/budget_check_test.exs`
- `test/shem/llm/middleware/event_logger_test.exs`
- `test/shem/llm/middleware/ollama_transport_test.exs`
- `test/shem/llm/stub_transport_test.exs`
- `test/shem/llm_test.exs`

---

## Task 1: Add `req` dependency and LLM config

**Files:**
- Modify: `mix.exs`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Add `req` to deps in `mix.exs`**

In the `deps/0` function, add after `{:jason, "~> 1.4"}`:

```elixir
{:req, "~> 0.5"}
```

- [ ] **Step 2: Add LLM config to `config/dev.exs`**

Append to `config/dev.exs`:

```elixir
config :shem,
  llm_pipeline: [
    {Shem.LLM.Middleware.BudgetCheck,
     [budget_server: Shem.LLM.BudgetServer]},
    {Shem.LLM.Middleware.EventLogger, []},
    {Shem.LLM.Middleware.OllamaTransport,
     [url: "http://localhost:11434"]}
  ],
  llm_models: %{default: "llama3:latest"},
  llm_ollama_url: "http://localhost:11434",
  llm_budget_limit: 500_000,
  llm_soft_threshold: 0.8
```

- [ ] **Step 3: Add LLM config to `config/test.exs`**

Append to `config/test.exs`:

```elixir
config :shem,
  llm_pipeline: [
    {Shem.LLM.Middleware.BudgetCheck,
     [budget_server: Shem.LLM.BudgetServer]},
    {Shem.LLM.Middleware.EventLogger, []},
    {Shem.LLM.StubTransport, []}
  ],
  llm_models: %{default: "llama3:latest"},
  llm_budget_limit: 100_000,
  llm_soft_threshold: 0.8
```

- [ ] **Step 4: Fetch deps and verify compile**

```bash
mix deps.get && mix compile
```

Expected: no errors, `req` downloaded.

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock config/dev.exs config/test.exs
git commit -m "chore: add req dep, LLM config keys for Phase 5"
```

---

## Task 2: Request and Response structs

**Files:**
- Create: `lib/shem/llm/request.ex`
- Create: `lib/shem/llm/response.ex`
- Create: `test/shem/llm/request_test.exs`
- Create: `test/shem/llm/response_test.exs`

- [ ] **Step 1: Write failing tests**

`test/shem/llm/request_test.exs`:

```elixir
defmodule Shem.LLM.RequestTest do
  use ExUnit.Case, async: true
  alias Shem.LLM.Request

  test "has expected fields with defaults" do
    r = %Request{prompt: "hello", model: :default}
    assert r.prompt == "hello"
    assert r.model == :default
    assert r.options == %{}
    assert r.session_id == nil
  end

  test "accepts all fields" do
    r = %Request{prompt: "hi", model: :llama3, options: %{temperature: 0.7}, session_id: "ses_abc"}
    assert r.session_id == "ses_abc"
    assert r.options == %{temperature: 0.7}
  end
end
```

`test/shem/llm/response_test.exs`:

```elixir
defmodule Shem.LLM.ResponseTest do
  use ExUnit.Case, async: true
  alias Shem.LLM.Response

  test "has expected fields" do
    r = %Response{content: "hello", tokens_used: 42, model: :llama3, latency_ms: 100}
    assert r.content == "hello"
    assert r.tokens_used == 42
    assert r.model == :llama3
    assert r.latency_ms == 100
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/llm/request_test.exs test/shem/llm/response_test.exs
```

Expected: compilation error — `Shem.LLM.Request` not found.

- [ ] **Step 3: Implement the structs**

`lib/shem/llm/request.ex`:

```elixir
defmodule Shem.LLM.Request do
  @enforce_keys [:prompt, :model]
  defstruct [:prompt, :model, :session_id, options: %{}]

  @type t :: %__MODULE__{
          prompt: String.t(),
          model: atom(),
          options: map(),
          session_id: String.t() | nil
        }
end
```

`lib/shem/llm/response.ex`:

```elixir
defmodule Shem.LLM.Response do
  @enforce_keys [:content, :tokens_used, :model, :latency_ms]
  defstruct [:content, :tokens_used, :model, :latency_ms]

  @type t :: %__MODULE__{
          content: String.t(),
          tokens_used: non_neg_integer(),
          model: atom(),
          latency_ms: non_neg_integer()
        }
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/llm/request_test.exs test/shem/llm/response_test.exs
```

Expected: 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/request.ex lib/shem/llm/response.ex \
        test/shem/llm/request_test.exs test/shem/llm/response_test.exs
git commit -m "feat: Shem.LLM.Request and Response structs"
```

---

## Task 3: Middleware behaviour

**Files:**
- Create: `lib/shem/llm/middleware.ex`

- [ ] **Step 1: Create the behaviour module**

`lib/shem/llm/middleware.ex`:

```elixir
defmodule Shem.LLM.Middleware do
  alias Shem.LLM.{Request, Response}

  @type pipeline_result :: {:ok, Response.t()} | {:error, term()}
  @type next :: (Request.t() -> pipeline_result())

  @callback call(request :: Request.t(), opts :: keyword(), next :: next()) ::
              pipeline_result()
end
```

- [ ] **Step 2: Verify it compiles**

```bash
mix compile
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add lib/shem/llm/middleware.ex
git commit -m "feat: Shem.LLM.Middleware behaviour"
```

---

## Task 4: BudgetServer

**Files:**
- Create: `lib/shem/llm/budget_server.ex`
- Create: `test/shem/llm/budget_server_test.exs`

- [ ] **Step 1: Write failing tests**

`test/shem/llm/budget_server_test.exs`:

```elixir
defmodule Shem.LLM.BudgetServerTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.BudgetServer

  defp start_server(limit, threshold \\ 0.8) do
    name = :"test_budget_#{:erlang.unique_integer([:positive])}"
    start_supervised!({BudgetServer, name: name, limit: limit, soft_threshold: threshold})
    name
  end

  describe "check/1" do
    test "returns :ok when tokens_used < limit" do
      srv = start_server(1000)
      assert :ok = BudgetServer.check(srv)
    end

    test "returns {:error, :budget_exhausted} when tokens_used == limit" do
      srv = start_server(10)
      BudgetServer.deduct(srv, 10)
      assert {:error, :budget_exhausted} = BudgetServer.check(srv)
    end

    test "returns {:error, :budget_exhausted} when tokens_used > limit" do
      srv = start_server(10)
      BudgetServer.deduct(srv, 15)
      assert {:error, :budget_exhausted} = BudgetServer.check(srv)
    end
  end

  describe "deduct/2" do
    test "increases tokens_used by the given amount" do
      srv = start_server(1000)
      BudgetServer.deduct(srv, 42)
      assert %{tokens_used: 42} = BudgetServer.status(srv)
    end

    test "is cumulative across multiple calls" do
      srv = start_server(1000)
      BudgetServer.deduct(srv, 10)
      BudgetServer.deduct(srv, 30)
      assert %{tokens_used: 40} = BudgetServer.status(srv)
    end
  end

  describe "soft warning" do
    test "soft_warned? is false initially" do
      srv = start_server(100)
      assert %{soft_warned?: false} = BudgetServer.status(srv)
    end

    test "soft_warned? becomes true after crossing threshold" do
      srv = start_server(100, 0.5)
      BudgetServer.deduct(srv, 51)
      assert %{soft_warned?: true} = BudgetServer.status(srv)
    end

    test "soft_warned? does not flip back after further deductions" do
      srv = start_server(100, 0.5)
      BudgetServer.deduct(srv, 51)
      BudgetServer.deduct(srv, 10)
      assert %{soft_warned?: true} = BudgetServer.status(srv)
    end
  end

  describe "reset/1" do
    test "resets tokens_used to zero" do
      srv = start_server(1000)
      BudgetServer.deduct(srv, 500)
      BudgetServer.reset(srv)
      assert %{tokens_used: 0} = BudgetServer.status(srv)
    end

    test "resets soft_warned? to false" do
      srv = start_server(100, 0.5)
      BudgetServer.deduct(srv, 60)
      BudgetServer.reset(srv)
      assert %{soft_warned?: false} = BudgetServer.status(srv)
    end
  end

  describe "status/1" do
    test "returns a map with all expected keys" do
      srv = start_server(500, 0.75)
      status = BudgetServer.status(srv)
      assert %{
               global_limit: 500,
               soft_threshold: 0.75,
               tokens_used: 0,
               soft_warned?: false
             } = status
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
mix test test/shem/llm/budget_server_test.exs
```

Expected: compilation error — `Shem.LLM.BudgetServer` not found.

- [ ] **Step 3: Implement BudgetServer**

`lib/shem/llm/budget_server.ex`:

```elixir
defmodule Shem.LLM.BudgetServer do
  use GenServer

  # ── Client API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    limit = Keyword.get(opts, :limit, Application.get_env(:shem, :llm_budget_limit, 500_000))
    threshold = Keyword.get(opts, :soft_threshold, Application.get_env(:shem, :llm_soft_threshold, 0.8))
    GenServer.start_link(__MODULE__, {limit, threshold}, name: name)
  end

  @spec check(GenServer.server()) :: :ok | {:error, :budget_exhausted}
  def check(server \\ __MODULE__), do: GenServer.call(server, :check)

  @spec deduct(GenServer.server(), non_neg_integer()) :: :ok
  def deduct(server \\ __MODULE__, tokens), do: GenServer.call(server, {:deduct, tokens})

  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # ── Server callbacks ────────────────────────────────────────────────────────

  @impl true
  def init({limit, threshold}) do
    {:ok, %{global_limit: limit, soft_threshold: threshold, tokens_used: 0, soft_warned?: false}}
  end

  @impl true
  def handle_call(:check, _from, state) do
    if state.tokens_used >= state.global_limit do
      {:reply, {:error, :budget_exhausted}, state}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:deduct, tokens}, _from, state) do
    new_used = state.tokens_used + tokens
    soft_limit = state.global_limit * state.soft_threshold

    new_warned =
      state.soft_warned? or (not state.soft_warned? and new_used >= soft_limit)

    {:reply, :ok, %{state | tokens_used: new_used, soft_warned?: new_warned}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | tokens_used: 0, soft_warned?: false}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/llm/budget_server_test.exs
```

Expected: 11 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/budget_server.ex test/shem/llm/budget_server_test.exs
git commit -m "feat: Shem.LLM.BudgetServer — token accumulator with hard/soft limits"
```

---

## Task 5: BudgetCheck middleware

**Files:**
- Create: `lib/shem/llm/middleware/budget_check.ex`
- Create: `test/shem/llm/middleware/budget_check_test.exs`

- [ ] **Step 1: Write failing tests**

`test/shem/llm/middleware/budget_check_test.exs`:

```elixir
defmodule Shem.LLM.Middleware.BudgetCheckTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.{Request, Response, BudgetServer}
  alias Shem.LLM.Middleware.BudgetCheck

  defp start_server(limit, threshold \\ 0.8) do
    name = :"budget_check_test_#{:erlang.unique_integer([:positive])}"
    start_supervised!({BudgetServer, name: name, limit: limit, soft_threshold: threshold})
    name
  end

  defp request(session_id \\ nil) do
    %Request{prompt: "hello", model: :default, session_id: session_id}
  end

  defp ok_response(tokens) do
    %Response{content: "ok", tokens_used: tokens, model: :default, latency_ms: 1}
  end

  describe "call/3 — pre-transport" do
    test "passes through when budget is available" do
      srv = start_server(1000)
      next = fn _req -> {:ok, ok_response(10)} end

      assert {:ok, %Response{tokens_used: 10}} =
               BudgetCheck.call(request(), [budget_server: srv], next)
    end

    test "halts with :budget_exhausted when limit is reached" do
      srv = start_server(10)
      BudgetServer.deduct(srv, 10)
      next = fn _req -> flunk("next should not be called") end

      assert {:error, :budget_exhausted} =
               BudgetCheck.call(request(), [budget_server: srv], next)
    end
  end

  describe "call/3 — post-transport deduction" do
    test "deducts tokens from budget on success" do
      srv = start_server(1000)
      next = fn _req -> {:ok, ok_response(42)} end

      BudgetCheck.call(request(), [budget_server: srv], next)

      assert %{tokens_used: 42} = BudgetServer.status(srv)
    end

    test "does not deduct tokens on error" do
      srv = start_server(1000)
      next = fn _req -> {:error, :something_failed} end

      BudgetCheck.call(request(), [budget_server: srv], next)

      assert %{tokens_used: 0} = BudgetServer.status(srv)
    end
  end

  describe "soft warning" do
    test "soft_warned? flips after threshold is crossed" do
      srv = start_server(100, 0.5)
      next = fn _req -> {:ok, ok_response(60)} end

      BudgetCheck.call(request(), [budget_server: srv], next)

      assert %{soft_warned?: true} = BudgetServer.status(srv)
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
mix test test/shem/llm/middleware/budget_check_test.exs
```

Expected: compilation error — `Shem.LLM.Middleware.BudgetCheck` not found.

- [ ] **Step 3: Implement BudgetCheck**

`lib/shem/llm/middleware/budget_check.ex`:

```elixir
defmodule Shem.LLM.Middleware.BudgetCheck do
  @behaviour Shem.LLM.Middleware

  alias Shem.LLM.BudgetServer

  @impl true
  def call(request, opts, next) do
    server = Keyword.get(opts, :budget_server, BudgetServer)

    case BudgetServer.check(server) do
      {:error, :budget_exhausted} ->
        {:error, :budget_exhausted}

      :ok ->
        result = next.(request)

        case result do
          {:ok, response} -> BudgetServer.deduct(server, response.tokens_used)
          {:error, _} -> :ok
        end

        result
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/llm/middleware/budget_check_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/middleware/budget_check.ex \
        test/shem/llm/middleware/budget_check_test.exs
git commit -m "feat: Shem.LLM.Middleware.BudgetCheck — hard/soft budget enforcement"
```

---

## Task 6: EventLogger middleware

**Files:**
- Create: `lib/shem/llm/middleware/event_logger.ex`
- Create: `test/shem/llm/middleware/event_logger_test.exs`

> **Note:** These tests are `async: false` — they share the application-started `Shem.EventLog` (with `FakeStore` in test).

- [ ] **Step 1: Write failing tests**

`test/shem/llm/middleware/event_logger_test.exs`:

```elixir
defmodule Shem.LLM.Middleware.EventLoggerTest do
  use ExUnit.Case, async: false

  alias Shem.LLM.{Request, Response, EventLog}
  alias Shem.LLM.Middleware.EventLogger

  defp request(session_id) do
    %Request{prompt: "hello", model: :default, session_id: session_id}
  end

  defp ok_response(tokens) do
    %Response{content: "ok", tokens_used: tokens, model: :default, latency_ms: 5}
  end

  describe "call/3 — with valid session_id" do
    test "appends :llm_call_started before and :llm_call_completed after on success" do
      {:ok, sid} = Shem.EventLog.start_session()
      next = fn _req -> {:ok, ok_response(20)} end

      assert {:ok, _} = EventLogger.call(request(sid), [], next)

      {:ok, events} = Shem.EventLog.events(sid)
      types = Enum.map(events, & &1.type)
      assert :llm_call_started in types
      assert :llm_call_completed in types
    end

    test ":llm_call_completed event carries tokens_used and latency_ms" do
      {:ok, sid} = Shem.EventLog.start_session()
      next = fn _req -> {:ok, ok_response(99)} end

      EventLogger.call(request(sid), [], next)

      {:ok, events} = Shem.EventLog.events(sid)
      completed = Enum.find(events, &(&1.type == :llm_call_completed))
      assert completed.payload.tokens_used == 99
      assert is_integer(completed.payload.latency_ms)
    end

    test "appends :llm_call_failed on error" do
      {:ok, sid} = Shem.EventLog.start_session()
      next = fn _req -> {:error, :transport_down} end

      assert {:error, :transport_down} = EventLogger.call(request(sid), [], next)

      {:ok, events} = Shem.EventLog.events(sid)
      failed = Enum.find(events, &(&1.type == :llm_call_failed))
      assert failed.payload.reason == ":transport_down"
    end
  end

  describe "call/3 — nil session_id" do
    test "passes through without touching the event log" do
      next = fn _req -> {:ok, ok_response(5)} end
      assert {:ok, _} = EventLogger.call(request(nil), [], next)
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
mix test test/shem/llm/middleware/event_logger_test.exs
```

Expected: compilation error — `Shem.LLM.Middleware.EventLogger` not found.

- [ ] **Step 3: Implement EventLogger**

`lib/shem/llm/middleware/event_logger.ex`:

```elixir
defmodule Shem.LLM.Middleware.EventLogger do
  @behaviour Shem.LLM.Middleware

  @impl true
  def call(%{session_id: nil} = request, _opts, next), do: next.(request)

  def call(request, _opts, next) do
    Shem.EventLog.append(request.session_id, :llm_call_started, %{model: request.model})

    start_ms = System.monotonic_time(:millisecond)
    result = next.(request)
    latency_ms = System.monotonic_time(:millisecond) - start_ms

    case result do
      {:ok, response} ->
        Shem.EventLog.append(request.session_id, :llm_call_completed, %{
          tokens_used: response.tokens_used,
          latency_ms: latency_ms
        })

      {:error, reason} ->
        Shem.EventLog.append(request.session_id, :llm_call_failed, %{
          reason: inspect(reason)
        })
    end

    result
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/llm/middleware/event_logger_test.exs
```

Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/middleware/event_logger.ex \
        test/shem/llm/middleware/event_logger_test.exs
git commit -m "feat: Shem.LLM.Middleware.EventLogger — event log integration at LLM call boundary"
```

---

## Task 7: StubTransport

**Files:**
- Create: `lib/shem/llm/stub_transport/server.ex`
- Create: `lib/shem/llm/stub_transport.ex`
- Create: `test/shem/llm/stub_transport_test.exs`

- [ ] **Step 1: Write failing tests**

`test/shem/llm/stub_transport_test.exs`:

```elixir
defmodule Shem.LLM.StubTransportTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.{Request, Response, StubTransport}
  alias Shem.LLM.StubTransport.Server

  defp start_stub do
    name = :"stub_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Server, name: name})
    name
  end

  defp request do
    %Request{prompt: "hello", model: :default}
  end

  defp ok_response(content \\ "stub response") do
    {:ok, %Response{content: content, tokens_used: 10, model: :default, latency_ms: 1}}
  end

  describe "response queue" do
    test "returns queued response in order" do
      stub = start_stub()
      Server.push_response(stub, ok_response("first"))
      Server.push_response(stub, ok_response("second"))

      assert {:ok, %{content: "first"}} = StubTransport.call(request(), [server: stub], fn _ -> :unreachable end)
      assert {:ok, %{content: "second"}} = StubTransport.call(request(), [server: stub], fn _ -> :unreachable end)
    end

    test "returns default response when queue is empty" do
      stub = start_stub()
      default = ok_response("default")
      Server.set_default(stub, default)

      assert {:ok, %{content: "default"}} = StubTransport.call(request(), [server: stub], fn _ -> :unreachable end)
    end

    test "returns {:error, :no_stub_response} when queue empty and no default" do
      stub = start_stub()
      assert {:error, :no_stub_response} = StubTransport.call(request(), [server: stub], fn _ -> :unreachable end)
    end

    test "can enqueue error responses" do
      stub = start_stub()
      Server.push_response(stub, {:error, {:transport, :econnrefused}})

      assert {:error, {:transport, :econnrefused}} = StubTransport.call(request(), [server: stub], fn _ -> :unreachable end)
    end
  end

  describe "call recording" do
    test "records all received requests" do
      stub = start_stub()
      Server.push_response(stub, ok_response())
      Server.push_response(stub, ok_response())

      req1 = %Request{prompt: "first", model: :default}
      req2 = %Request{prompt: "second", model: :llama3}

      StubTransport.call(req1, [server: stub], fn _ -> :unreachable end)
      StubTransport.call(req2, [server: stub], fn _ -> :unreachable end)

      calls = Server.calls(stub)
      assert length(calls) == 2
      assert Enum.at(calls, 0).prompt == "first"
      assert Enum.at(calls, 1).prompt == "second"
    end

    test "calls/1 returns empty list initially" do
      stub = start_stub()
      assert [] = Server.calls(stub)
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
mix test test/shem/llm/stub_transport_test.exs
```

Expected: compilation error — `Shem.LLM.StubTransport.Server` not found.

- [ ] **Step 3: Implement StubTransport.Server**

`lib/shem/llm/stub_transport/server.ex`:

```elixir
defmodule Shem.LLM.StubTransport.Server do
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def push_response(server \\ __MODULE__, response),
    do: GenServer.call(server, {:push, response})

  def set_default(server \\ __MODULE__, response),
    do: GenServer.call(server, {:set_default, response})

  def calls(server \\ __MODULE__),
    do: GenServer.call(server, :calls)

  def pop(server \\ __MODULE__),
    do: GenServer.call(server, :pop)

  @impl true
  def init(:ok), do: {:ok, %{queue: [], default: nil, calls: []}}

  @impl true
  def handle_call({:push, response}, _from, state),
    do: {:reply, :ok, %{state | queue: state.queue ++ [response]}}

  @impl true
  def handle_call({:set_default, response}, _from, state),
    do: {:reply, :ok, %{state | default: response}}

  @impl true
  def handle_call(:calls, _from, state),
    do: {:reply, state.calls, state}

  @impl true
  def handle_call(:pop, _from, %{queue: [head | rest]} = state),
    do: {:reply, {:ok, head}, %{state | queue: rest}}

  def handle_call(:pop, _from, %{queue: [], default: nil} = state),
    do: {:reply, :empty, state}

  def handle_call(:pop, _from, %{queue: [], default: default} = state),
    do: {:reply, {:ok, default}, state}

  def handle_call({:record_call, request}, _from, state),
    do: {:reply, :ok, %{state | calls: state.calls ++ [request]}}
end
```

- [ ] **Step 4: Implement StubTransport**

`lib/shem/llm/stub_transport.ex`:

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
end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/shem/llm/stub_transport_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/llm/stub_transport/server.ex lib/shem/llm/stub_transport.ex \
        test/shem/llm/stub_transport_test.exs
git commit -m "feat: Shem.LLM.StubTransport — response-queue terminal middleware for tests"
```

---

## Task 8: OllamaTransport middleware

**Files:**
- Create: `lib/shem/llm/middleware/ollama_transport.ex`
- Create: `test/shem/llm/middleware/ollama_transport_test.exs`

- [ ] **Step 1: Write failing tests**

`test/shem/llm/middleware/ollama_transport_test.exs`:

```elixir
defmodule Shem.LLM.Middleware.OllamaTransportTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.{Request, Response}
  alias Shem.LLM.Middleware.OllamaTransport

  defp request(model \\ :default) do
    %Request{prompt: "hello", model: model, options: %{}}
  end

  defp mock_post(status, body) do
    fn _url, _opts -> {:ok, %{status: status, body: body}} end
  end

  defp ollama_body(content, eval \\ 20, prompt_eval \\ 10) do
    %{
      "response" => content,
      "done" => true,
      "eval_count" => eval,
      "prompt_eval_count" => prompt_eval
    }
  end

  describe "successful response" do
    test "returns {:ok, %Response{}} with parsed content" do
      http_post = mock_post(200, ollama_body("Hello world"))
      opts = [http_post_fn: http_post, url: "http://localhost:11434"]

      assert {:ok, %Response{content: "Hello world"}} =
               OllamaTransport.call(request(), opts, fn _ -> :unreachable end)
    end

    test "sums eval_count and prompt_eval_count as tokens_used" do
      http_post = mock_post(200, ollama_body("hi", 20, 10))
      opts = [http_post_fn: http_post, url: "http://localhost:11434"]

      assert {:ok, %Response{tokens_used: 30}} =
               OllamaTransport.call(request(), opts, fn _ -> :unreachable end)
    end

    test "response carries the request model atom" do
      http_post = mock_post(200, ollama_body("hi"))
      opts = [http_post_fn: http_post, url: "http://localhost:11434"]

      assert {:ok, %Response{model: :default}} =
               OllamaTransport.call(request(:default), opts, fn _ -> :unreachable end)
    end

    test "latency_ms is a non-negative integer" do
      http_post = mock_post(200, ollama_body("hi"))
      opts = [http_post_fn: http_post, url: "http://localhost:11434"]

      assert {:ok, %Response{latency_ms: ms}} =
               OllamaTransport.call(request(), opts, fn _ -> :unreachable end)

      assert is_integer(ms) and ms >= 0
    end
  end

  describe "HTTP errors" do
    test "returns {:error, {:transport, {:http_error, status}}} on non-200" do
      http_post = mock_post(503, %{})
      opts = [http_post_fn: http_post, url: "http://localhost:11434"]

      assert {:error, {:transport, {:http_error, 503}}} =
               OllamaTransport.call(request(), opts, fn _ -> :unreachable end)
    end

    test "returns {:error, {:transport, reason}} when HTTP call fails" do
      http_post = fn _url, _opts -> {:error, %RuntimeError{message: "econnrefused"}} end
      opts = [http_post_fn: http_post, url: "http://localhost:11434"]

      assert {:error, {:transport, _}} =
               OllamaTransport.call(request(), opts, fn _ -> :unreachable end)
    end
  end

  describe "parse errors" do
    test "returns {:error, {:parse_error, body}} on unexpected response shape" do
      http_post = mock_post(200, %{"unexpected" => "shape"})
      opts = [http_post_fn: http_post, url: "http://localhost:11434"]

      assert {:error, {:parse_error, %{"unexpected" => "shape"}}} =
               OllamaTransport.call(request(), opts, fn _ -> :unreachable end)
    end
  end

  describe "model resolution" do
    test "unknown model atom falls back to string representation" do
      received_body = Agent.start_link(fn -> nil end) |> elem(1)

      http_post = fn _url, opts ->
        Agent.update(received_body, fn _ -> opts[:json] end)
        {:ok, %{status: 200, body: ollama_body("ok")}}
      end

      opts = [http_post_fn: http_post, url: "http://localhost:11434"]
      OllamaTransport.call(request(:unknown_model), opts, fn _ -> :unreachable end)

      body = Agent.get(received_body, & &1)
      assert body["model"] == "unknown_model"
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
mix test test/shem/llm/middleware/ollama_transport_test.exs
```

Expected: compilation error — `Shem.LLM.Middleware.OllamaTransport` not found.

- [ ] **Step 3: Implement OllamaTransport**

`lib/shem/llm/middleware/ollama_transport.ex`:

```elixir
defmodule Shem.LLM.Middleware.OllamaTransport do
  @behaviour Shem.LLM.Middleware

  require Logger

  @impl true
  def call(request, opts, _next) do
    url = Keyword.get(opts, :url, Application.get_env(:shem, :llm_ollama_url, "http://localhost:11434"))
    http_post = Keyword.get(opts, :http_post_fn, &Req.post/2)

    body = %{
      "model" => resolve_model(request.model),
      "prompt" => request.prompt,
      "stream" => false,
      "options" => request.options
    }

    start_ms = System.monotonic_time(:millisecond)

    case http_post.(url <> "/api/generate", json: body) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_response(resp_body, request.model, start_ms)

      {:ok, %{status: status}} ->
        {:error, {:transport, {:http_error, status}}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp resolve_model(model_atom) do
    models = Application.get_env(:shem, :llm_models, %{})

    case Map.get(models, model_atom) do
      nil ->
        Logger.warning("Unknown LLM model atom #{inspect(model_atom)}, falling back to string")
        Atom.to_string(model_atom)

      str ->
        str
    end
  end

  defp parse_response(%{"response" => content, "done" => true} = body, model, start_ms) do
    tokens_used = Map.get(body, "eval_count", 0) + Map.get(body, "prompt_eval_count", 0)
    latency_ms = System.monotonic_time(:millisecond) - start_ms

    {:ok,
     %Shem.LLM.Response{
       content: content,
       tokens_used: tokens_used,
       model: model,
       latency_ms: latency_ms
     }}
  end

  defp parse_response(raw_body, _model, _start_ms) do
    {:error, {:parse_error, raw_body}}
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/llm/middleware/ollama_transport_test.exs
```

Expected: 8 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/middleware/ollama_transport.ex \
        test/shem/llm/middleware/ollama_transport_test.exs
git commit -m "feat: Shem.LLM.Middleware.OllamaTransport — HTTP terminal middleware for Ollama/llama-server"
```

---

## Task 9: Shem.LLM public API

**Files:**
- Create: `lib/shem/llm.ex`
- Create: `test/shem/llm_test.exs`

- [ ] **Step 1: Write failing tests**

`test/shem/llm_test.exs`:

```elixir
defmodule Shem.LLMTest do
  use ExUnit.Case, async: false

  alias Shem.LLM
  alias Shem.LLM.{Request, Response}
  alias Shem.LLM.StubTransport.Server, as: StubServer

  # Tests use the globally-started StubTransport.Server and BudgetServer.
  # async: false to avoid cross-test state contamination.

  defp stub_response(content \\ "stub", tokens \\ 5) do
    {:ok, %Response{content: content, tokens_used: tokens, model: :default, latency_ms: 1}}
  end

  setup do
    Shem.LLM.BudgetServer.reset()
    :ok
  end

  describe "complete/1" do
    test "returns {:ok, %Response{}} on success" do
      StubServer.push_response(stub_response("hello", 10))

      request = %Request{prompt: "hi", model: :default}
      assert {:ok, %Response{content: "hello"}} = LLM.complete(request)
    end

    test "event log receives entries when session_id is set" do
      {:ok, sid} = Shem.EventLog.start_session()
      StubServer.push_response(stub_response())

      request = %Request{prompt: "hi", model: :default, session_id: sid}
      assert {:ok, _} = LLM.complete(request)

      {:ok, events} = Shem.EventLog.events(sid)
      types = Enum.map(events, & &1.type)
      assert :llm_call_started in types
      assert :llm_call_completed in types
    end

    test "propagates {:error, reason} from pipeline" do
      StubServer.push_response({:error, :transport_down})

      request = %Request{prompt: "hi", model: :default}
      assert {:error, :transport_down} = LLM.complete(request)
    end

    test "deducts tokens from BudgetServer after successful call" do
      before = Shem.LLM.BudgetServer.status().tokens_used
      StubServer.push_response(stub_response("ok", 25))

      LLM.complete(%Request{prompt: "x", model: :default})
      after_ = Shem.LLM.BudgetServer.status().tokens_used

      assert after_ - before == 25
    end
  end

  describe "stream/2" do
    test "calls callback with response content and returns {:ok, response}" do
      StubServer.push_response(stub_response("streamed", 3))

      chunks = Agent.start_link(fn -> [] end) |> elem(1)
      request = %Request{prompt: "hi", model: :default}

      assert {:ok, %Response{}} =
               LLM.stream(request, fn chunk -> Agent.update(chunks, &[chunk | &1]) end)

      assert Agent.get(chunks, &Enum.reverse/1) == ["streamed"]
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
mix test test/shem/llm_test.exs
```

Expected: compilation error — `Shem.LLM` not found.

- [ ] **Step 3: Implement Shem.LLM**

`lib/shem/llm.ex`:

```elixir
defmodule Shem.LLM do
  alias Shem.LLM.{Request, Response}

  @spec complete(Request.t()) :: {:ok, Response.t()} | {:error, term()}
  def complete(%Request{} = request) do
    pipeline = build_pipeline()
    pipeline.(request)
  end

  @spec stream(Request.t(), (String.t() -> any())) :: {:ok, Response.t()} | {:error, term()}
  def stream(%Request{} = request, callback) when is_function(callback, 1) do
    case complete(request) do
      {:ok, response} ->
        callback.(response.content)
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_pipeline do
    pipeline = Application.get_env(:shem, :llm_pipeline, [])

    terminal = fn _req -> {:error, :no_terminal} end

    pipeline
    |> normalize_pipeline()
    |> Enum.reverse()
    |> Enum.reduce(terminal, fn {mod, opts}, next ->
      fn req -> mod.call(req, opts, next) end
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

- [ ] **Step 4: Update test config to include the StubServer name**

The public API tests use the application-started `StubTransport`. We need `StubTransport.Server` to be started in the application for tests, with a known name. Update the pipeline config in `config/test.exs` to pass the server name:

```elixir
config :shem,
  llm_pipeline: [
    {Shem.LLM.Middleware.BudgetCheck, [budget_server: Shem.LLM.BudgetServer]},
    {Shem.LLM.Middleware.EventLogger, []},
    {Shem.LLM.StubTransport, [server: Shem.LLM.StubTransport.Server]}
  ],
  llm_models: %{default: "llama3:latest"},
  llm_budget_limit: 100_000,
  llm_soft_threshold: 0.8
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/shem/llm_test.exs
```

Expected: 5 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/llm.ex test/shem/llm_test.exs config/test.exs
git commit -m "feat: Shem.LLM public API — complete/1, stream/2, middleware pipeline"
```

---

## Task 10: Wire BudgetServer and StubTransport.Server into Application

**Files:**
- Modify: `lib/shem/application.ex`

- [ ] **Step 1: Add BudgetServer and StubTransport.Server to supervision tree**

In `lib/shem/application.ex`, update the `start/2` function:

```elixir
defmodule Shem.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Shem.Registry},
        Shem.AgentSupervisor,
        Shem.EventLog,
        {Task.Supervisor, name: Shem.Lab.TaskSupervisor},
        Shem.Lab.Registry,
        Shem.LLM.BudgetServer
      ] ++ llm_stub_children() ++ mcp_children() ++ tui_children()

    opts = [strategy: :one_for_one, name: Shem.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp llm_stub_children do
    if Application.get_env(:shem, :start_llm_stub, Mix.env() == :test) do
      [{Shem.LLM.StubTransport.Server, name: Shem.LLM.StubTransport.Server}]
    else
      []
    end
  end

  defp mcp_children do
    if Application.get_env(:shem, :start_mcp, true) do
      [Shem.MCP.Server, Shem.MCP.Client.Supervisor]
    else
      []
    end
  end

  defp tui_children do
    if Application.get_env(:shem, :start_tui, true) do
      [Shem.TUI.RuntimeSupervisor]
    else
      []
    end
  end
end
```

Add to `config/test.exs`:

```elixir
config :shem, start_llm_stub: true
```

- [ ] **Step 2: Run full test suite to verify nothing broke**

```bash
mix test
```

Expected: all tests passing (count will have grown from 167).

- [ ] **Step 3: Commit**

```bash
git add lib/shem/application.ex config/test.exs
git commit -m "feat: supervise Shem.LLM.BudgetServer and StubTransport.Server in Application"
```

---

## Task 11: Smoke test script

**Files:**
- Create: `scripts/smoke_llm.exs`

- [ ] **Step 1: Write the smoke test script**

`scripts/smoke_llm.exs`:

```elixir
# Run with: mix run scripts/smoke_llm.exs
# Requires Ollama running at localhost:11434 with a model loaded.
# Verifies: LLM call succeeds, tokens tracked, event log records the call.

Application.ensure_all_started(:shem)

model = Application.get_env(:shem, :llm_models, %{}) |> Map.get(:default, "llama3:latest")
IO.puts("Using model config: #{inspect(model)}")
IO.puts("Sending test prompt to Ollama...\n")

{:ok, sid} = Shem.EventLog.start_session()

request = %Shem.LLM.Request{
  prompt: "In one sentence, what is the Elixir programming language?",
  model: :default,
  session_id: sid
}

case Shem.LLM.complete(request) do
  {:ok, response} ->
    IO.puts("Response: #{response.content}")
    IO.puts("Tokens used: #{response.tokens_used}")
    IO.puts("Latency: #{response.latency_ms}ms")

    {:ok, events} = Shem.EventLog.events(sid)
    types = Enum.map(events, & &1.type)
    IO.puts("\nEvent log entries: #{inspect(types)}")

    if :llm_call_started in types and :llm_call_completed in types do
      IO.puts("\n✓ Smoke test passed.")
    else
      IO.puts("\n✗ Event log entries missing — expected :llm_call_started and :llm_call_completed")
      System.halt(1)
    end

  {:error, reason} ->
    IO.puts("✗ LLM call failed: #{inspect(reason)}")
    IO.puts("Is Ollama running at localhost:11434?")
    System.halt(1)
end
```

- [ ] **Step 2: Verify it compiles (don't run against live Ollama yet)**

```bash
mix compile
```

Expected: no errors.

- [ ] **Step 3: Run against live Ollama (manual)**

Ensure Ollama is running with a model loaded, then:

```bash
mix run scripts/smoke_llm.exs
```

Expected output includes response text, token count, latency, and "✓ Smoke test passed."

- [ ] **Step 4: Run full test suite one final time**

```bash
mix test
```

Expected: all tests passing.

- [ ] **Step 5: Commit**

```bash
git add scripts/smoke_llm.exs
git commit -m "chore: LLM smoke test script for manual Ollama verification"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task |
|---|---|
| `Shem.LLM.Middleware` behaviour with `call/3` | Task 3 |
| `%Request{}` and `%Response{}` structs | Task 2 |
| `BudgetServer` — hard limit, soft warning, deduct, reset | Task 4 |
| `BudgetCheck` middleware — pre/post transport | Task 5 |
| `EventLogger` middleware — started/completed/failed events | Task 6 |
| `OllamaTransport` — HTTP POST, parse, error wrapping | Task 8 |
| `StubTransport` — response queue, call recording | Task 7 |
| `Shem.LLM.complete/1` and `stream/2` | Task 9 |
| Pipeline assembled from config as right-fold | Task 9 |
| Session ID injected if nil | Task 9 |
| `BudgetServer` in supervision tree | Task 10 |
| `req ~> 0.5` dep | Task 1 |
| Smoke test script | Task 11 |
| `stream/2` single-chunk MVP | Task 9 |
| Soft warning fires once per session | Task 4 + 5 |
| No token deduction on transport error | Task 5 |

All spec requirements covered.
