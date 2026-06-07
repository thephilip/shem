# Phase 15 — Cloud LLM Transports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add OpenAI and Anthropic as first-class LLM backends wired into the existing `RouterTransport` pipeline, with TUI support for routing to cloud models via `/llm route default=openai:gpt-4o`.

**Architecture:** Two new transport modules (`OpenAITransport`, `AnthropicTransport`) implement `Shem.LLM.Middleware`. `Shem.LLM.Router` registers them as `:openai` and `:anthropic` backend atoms. `CommandDispatch` is extended to parse `role=backend:model` syntax. All configuration (API keys, HTTP client) comes from opts with env var defaults — no new config keys needed.

**Tech Stack:** Elixir/OTP, `Req` HTTP client (already a dep), ExUnit. No new dependencies.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `lib/shem/llm/middleware/openai_transport.ex` | Create | OpenAI chat completions transport |
| `lib/shem/llm/middleware/anthropic_transport.ex` | Create | Anthropic messages transport |
| `test/shem/llm/middleware/openai_transport_test.exs` | Create | OpenAI transport unit tests |
| `test/shem/llm/middleware/anthropic_transport_test.exs` | Create | Anthropic transport unit tests |
| `lib/shem/llm/router.ex` | Modify | Register `:openai` and `:anthropic` in `@backend_modules`; update `@spec` |
| `test/shem/llm/router_test.exs` | Modify | 2 new tests for new backends |
| `lib/shem/tui/command_dispatch.ex` | Modify | `backend:model` parse syntax; `@known_backends`; `parse_route_pair/2` helper |
| `test/shem/tui/command_dispatch_test.exs` | Modify | 5 new tests for `backend:model` parsing |
| `config/dev.exs` | Modify | Commented cloud route examples |

---

## Task 1: OpenAI Transport

**Files:**
- Create: `lib/shem/llm/middleware/openai_transport.ex`
- Create: `test/shem/llm/middleware/openai_transport_test.exs`

### Background

`OpenAITransport` calls `/v1/chat/completions` on `base_url` (default `https://api.openai.com`). It wraps `request.prompt` as a single user message. The `base_url:` opt means it also works with LM-Studio or any other OpenAI-compatible endpoint. Auth via `Authorization: Bearer <key>` header. All configuration comes from opts with env var / application config defaults.

Response shape from OpenAI:
```json
{
  "choices": [{"message": {"role": "assistant", "content": "Hello"}}],
  "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
}
```

- [ ] **Step 1: Write the failing tests**

Create `test/shem/llm/middleware/openai_transport_test.exs`:

```elixir
defmodule Shem.LLM.Middleware.OpenAITransportTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.Middleware.OpenAITransport
  alias Shem.LLM.{Request, Response}

  defp req(model \\ :default), do: %Request{prompt: "hello", model: model}

  defp mock_post(status, body) do
    fn _url, _opts -> {:ok, %{status: status, body: body}} end
  end

  defp success_body(content \\ "Hi there", tokens \\ 15) do
    %{
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
      "usage" => %{"total_tokens" => tokens}
    }
  end

  describe "call/3 — success" do
    test "returns Response with content, tokens_used, and latency_ms" do
      opts = [
        model_string: "gpt-4o",
        api_key: "sk-test",
        http_post_fn: mock_post(200, success_body("Hello", 20))
      ]

      assert {:ok, %Response{} = resp} = OpenAITransport.call(req(), opts, nil)
      assert resp.content == "Hello"
      assert resp.tokens_used == 20
      assert resp.latency_ms >= 0
      assert resp.model == :default
    end
  end

  describe "call/3 — HTTP errors" do
    test "401 returns {:error, {:transport, :unauthorized}}" do
      opts = [api_key: "bad-key", http_post_fn: mock_post(401, %{})]
      assert {:error, {:transport, :unauthorized}} = OpenAITransport.call(req(), opts, nil)
    end

    test "429 returns {:error, {:transport, :rate_limited}}" do
      opts = [api_key: "sk-test", http_post_fn: mock_post(429, %{})]
      assert {:error, {:transport, :rate_limited}} = OpenAITransport.call(req(), opts, nil)
    end

    test "500 returns {:error, {:transport, {:http_error, 500}}}" do
      opts = [api_key: "sk-test", http_post_fn: mock_post(500, %{})]
      assert {:error, {:transport, {:http_error, 500}}} = OpenAITransport.call(req(), opts, nil)
    end
  end

  describe "call/3 — parse errors" do
    test "malformed body returns {:error, {:parse_error, _}}" do
      opts = [api_key: "sk-test", http_post_fn: mock_post(200, %{"unexpected" => "shape"})]
      assert {:error, {:parse_error, _}} = OpenAITransport.call(req(), opts, nil)
    end
  end

  describe "call/3 — network error" do
    test "Req error returns {:error, {:transport, reason}}" do
      opts = [api_key: "sk-test", http_post_fn: fn _url, _opts -> {:error, :timeout} end]
      assert {:error, {:transport, :timeout}} = OpenAITransport.call(req(), opts, nil)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/llm/middleware/openai_transport_test.exs 2>&1 | tail -5
```

Expected: module not found error.

- [ ] **Step 3: Implement `OpenAITransport`**

Create `lib/shem/llm/middleware/openai_transport.ex`:

```elixir
defmodule Shem.LLM.Middleware.OpenAITransport do
  @behaviour Shem.LLM.Middleware

  @impl true
  def call(request, opts, _next) do
    base_url = Keyword.get(opts, :base_url, "https://api.openai.com")
    api_key = Keyword.get(opts, :api_key, System.get_env("OPENAI_API_KEY", ""))
    http_post = Keyword.get(opts, :http_post_fn, &Req.post/2)
    timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))
    model_string = Keyword.get(opts, :model_string, "gpt-4o")
    max_tokens = Map.get(request.options, :max_tokens, 512)

    body = %{
      "model" => model_string,
      "messages" => [%{"role" => "user", "content" => request.prompt}],
      "max_tokens" => max_tokens
    }

    headers = [{"authorization", "Bearer #{api_key}"}]
    start_ms = System.monotonic_time(:millisecond)

    case http_post.(base_url <> "/v1/chat/completions",
           json: body,
           headers: headers,
           receive_timeout: timeout_ms
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_response(resp_body, request.model, start_ms)

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

  defp parse_response(
         %{"choices" => [%{"message" => %{"content" => content}} | _], "usage" => usage},
         model,
         start_ms
       ) do
    tokens_used = Map.get(usage, "total_tokens", 0)
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
cd /home/philip/Downloads/_project/shem && mix test test/shem/llm/middleware/openai_transport_test.exs 2>&1 | tail -5
```

Expected: 5 passed.

- [ ] **Step 5: Run full suite to check for regressions**

```bash
cd /home/philip/Downloads/_project/shem && mix test 2>&1 | tail -5
```

Expected: 533 + 5 = 538 passed.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/llm/middleware/openai_transport.ex test/shem/llm/middleware/openai_transport_test.exs
git commit -m "feat: OpenAITransport — chat completions middleware with opts injection"
```

---

## Task 2: Anthropic Transport

**Files:**
- Create: `lib/shem/llm/middleware/anthropic_transport.ex`
- Create: `test/shem/llm/middleware/anthropic_transport_test.exs`

### Background

`AnthropicTransport` calls `https://api.anthropic.com/v1/messages`. Auth via `x-api-key: <key>` + `anthropic-version: 2023-06-01` headers. Wraps `request.prompt` as a single user message. `max_tokens` is required by the Anthropic API — always included.

Response shape from Anthropic:
```json
{
  "content": [{"type": "text", "text": "Hello"}],
  "usage": {"input_tokens": 10, "output_tokens": 5}
}
```

- [ ] **Step 1: Write the failing tests**

Create `test/shem/llm/middleware/anthropic_transport_test.exs`:

```elixir
defmodule Shem.LLM.Middleware.AnthropicTransportTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.Middleware.AnthropicTransport
  alias Shem.LLM.{Request, Response}

  defp req(model \\ :default), do: %Request{prompt: "hello", model: model}

  defp mock_post(status, body) do
    fn _url, _opts -> {:ok, %{status: status, body: body}} end
  end

  defp success_body(content \\ "Hi there", input \\ 10, output \\ 5) do
    %{
      "content" => [%{"type" => "text", "text" => content}],
      "usage" => %{"input_tokens" => input, "output_tokens" => output}
    }
  end

  describe "call/3 — success" do
    test "returns Response with content, tokens_used (input+output), and latency_ms" do
      opts = [
        model_string: "claude-sonnet-4-6",
        api_key: "sk-ant-test",
        http_post_fn: mock_post(200, success_body("Hello", 10, 5))
      ]

      assert {:ok, %Response{} = resp} = AnthropicTransport.call(req(), opts, nil)
      assert resp.content == "Hello"
      assert resp.tokens_used == 15
      assert resp.latency_ms >= 0
      assert resp.model == :default
    end
  end

  describe "call/3 — HTTP errors" do
    test "401 returns {:error, {:transport, :unauthorized}}" do
      opts = [api_key: "bad", http_post_fn: mock_post(401, %{})]
      assert {:error, {:transport, :unauthorized}} = AnthropicTransport.call(req(), opts, nil)
    end

    test "429 returns {:error, {:transport, :rate_limited}}" do
      opts = [api_key: "sk-ant-test", http_post_fn: mock_post(429, %{})]
      assert {:error, {:transport, :rate_limited}} = AnthropicTransport.call(req(), opts, nil)
    end

    test "500 returns {:error, {:transport, {:http_error, 500}}}" do
      opts = [api_key: "sk-ant-test", http_post_fn: mock_post(500, %{})]
      assert {:error, {:transport, {:http_error, 500}}} = AnthropicTransport.call(req(), opts, nil)
    end
  end

  describe "call/3 — parse errors" do
    test "malformed body returns {:error, {:parse_error, _}}" do
      opts = [api_key: "sk-ant-test", http_post_fn: mock_post(200, %{"unexpected" => "shape"})]
      assert {:error, {:parse_error, _}} = AnthropicTransport.call(req(), opts, nil)
    end
  end

  describe "call/3 — network error" do
    test "Req error returns {:error, {:transport, reason}}" do
      opts = [api_key: "sk-ant-test", http_post_fn: fn _url, _opts -> {:error, :econnrefused} end]
      assert {:error, {:transport, :econnrefused}} = AnthropicTransport.call(req(), opts, nil)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/llm/middleware/anthropic_transport_test.exs 2>&1 | tail -5
```

Expected: module not found error.

- [ ] **Step 3: Implement `AnthropicTransport`**

Create `lib/shem/llm/middleware/anthropic_transport.ex`:

```elixir
defmodule Shem.LLM.Middleware.AnthropicTransport do
  @behaviour Shem.LLM.Middleware

  @anthropic_version "2023-06-01"

  @impl true
  def call(request, opts, _next) do
    api_key = Keyword.get(opts, :api_key, System.get_env("ANTHROPIC_API_KEY", ""))
    http_post = Keyword.get(opts, :http_post_fn, &Req.post/2)
    timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))
    model_string = Keyword.get(opts, :model_string, "claude-sonnet-4-6")
    max_tokens = Map.get(request.options, :max_tokens, 512)

    body = %{
      "model" => model_string,
      "messages" => [%{"role" => "user", "content" => request.prompt}],
      "max_tokens" => max_tokens
    }

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_version}
    ]

    start_ms = System.monotonic_time(:millisecond)

    case http_post.("https://api.anthropic.com/v1/messages",
           json: body,
           headers: headers,
           receive_timeout: timeout_ms
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_response(resp_body, request.model, start_ms)

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

  defp parse_response(
         %{"content" => [%{"type" => "text", "text" => content} | _], "usage" => usage},
         model,
         start_ms
       ) do
    tokens_used = Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)
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
cd /home/philip/Downloads/_project/shem && mix test test/shem/llm/middleware/anthropic_transport_test.exs 2>&1 | tail -5
```

Expected: 5 passed.

- [ ] **Step 5: Run full suite to check for regressions**

```bash
cd /home/philip/Downloads/_project/shem && mix test 2>&1 | tail -5
```

Expected: 543 passed (538 + 5).

- [ ] **Step 6: Commit**

```bash
git add lib/shem/llm/middleware/anthropic_transport.ex test/shem/llm/middleware/anthropic_transport_test.exs
git commit -m "feat: AnthropicTransport — messages API middleware with opts injection"
```

---

## Task 3: Router — Register New Backends

**Files:**
- Modify: `lib/shem/llm/router.ex`
- Modify: `test/shem/llm/router_test.exs`

### Background

`@backend_modules` maps backend key atoms to transport modules. Adding `:openai` and `:anthropic` is a two-line change. The existing `build_transport/2` error path already handles unknown atoms — no other logic changes. The `@spec` annotations for `set_route/3` and `all/0` also need updating to include the new backend atoms.

- [ ] **Step 1: Write the failing tests**

In `test/shem/llm/router_test.exs`, add two tests inside the existing `describe "resolve/1"` block, after the `"returns OllamaTransport for :ollama backend"` test:

```elixir
test "returns OpenAITransport for :openai backend" do
  :ok = Router.set_route(:cloud, :openai, "gpt-4o")
  assert {Shem.LLM.Middleware.OpenAITransport, opts} = Router.resolve(:cloud)
  assert Keyword.get(opts, :model_string) == "gpt-4o"
end

test "returns AnthropicTransport for :anthropic backend" do
  :ok = Router.set_route(:cloud, :anthropic, "claude-sonnet-4-6")
  assert {Shem.LLM.Middleware.AnthropicTransport, opts} = Router.resolve(:cloud)
  assert Keyword.get(opts, :model_string) == "claude-sonnet-4-6"
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/llm/router_test.exs 2>&1 | tail -5
```

Expected: 2 failures — `{:error, {:unknown_backend, :openai}}` and `{:error, {:unknown_backend, :anthropic}}`.

- [ ] **Step 3: Update `lib/shem/llm/router.ex`**

Make three changes:

**1. Expand `@backend_modules`** (lines 4–7):

```elixir
@backend_modules %{
  llama_cpp: Shem.LLM.Middleware.LlamaCppTransport,
  ollama:    Shem.LLM.Middleware.OllamaTransport,
  openai:    Shem.LLM.Middleware.OpenAITransport,
  anthropic: Shem.LLM.Middleware.AnthropicTransport
}
```

**2. Update `@spec` for `set_route/3`** (line 18):

```elixir
@spec set_route(atom(), :llama_cpp | :ollama | :openai | :anthropic, String.t()) :: :ok
```

**3. Update `@spec` for `all/0`** (line 23):

```elixir
@spec all() :: %{atom() => {:llama_cpp | :ollama | :openai | :anthropic, String.t()}}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/llm/router_test.exs 2>&1 | tail -5
```

Expected: 10 passed (8 existing + 2 new).

- [ ] **Step 5: Run full suite to check for regressions**

```bash
cd /home/philip/Downloads/_project/shem && mix test 2>&1 | tail -5
```

Expected: 545 passed.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/llm/router.ex test/shem/llm/router_test.exs
git commit -m "feat: Router — register :openai and :anthropic backends"
```

---

## Task 4: CommandDispatch — `backend:model` Syntax

**Files:**
- Modify: `lib/shem/tui/command_dispatch.ex`
- Modify: `test/shem/tui/command_dispatch_test.exs`

### Background

The current `/llm route` parser always produces `{role, :llama_cpp, model_string}`. Extend it to parse `role=backend:model` pairs. If the value after `=` contains `:`, split on the first `:` to extract backend and model string, validate the backend against a known set, and return an error for unknown backends. Values without `:` default to `:llama_cpp` (backward compatible). An error on any pair short-circuits the whole command.

Add a `@known_backends` module attribute and a private `parse_route_pair/2` helper. Restructure the pair-processing pipeline to use `Enum.reduce_while/3` so a single bad pair returns an error rather than being silently dropped.

- [ ] **Step 1: Write the failing tests**

Add a new `describe` block at the bottom of `test/shem/tui/command_dispatch_test.exs`, before the final `end`:

```elixir
describe "parse/1 — /llm route backend:model syntax" do
  test "routes to openai with model string" do
    assert {:llm_route, [{:default, :openai, "gpt-4o"}]} =
             CommandDispatch.parse("/llm route default=openai:gpt-4o")
  end

  test "routes to anthropic with model string" do
    assert {:llm_route, [{:reasoning, :anthropic, "claude-sonnet-4-6"}]} =
             CommandDispatch.parse("/llm route reasoning=anthropic:claude-sonnet-4-6")
  end

  test "mixed batch: cloud and bare llama_cpp shorthand together" do
    assert {:llm_route, results} =
             CommandDispatch.parse("/llm route default=openai:gpt-4o tools=phi4")

    assert {:default, :openai, "gpt-4o"} in results
    assert {:tools, :llama_cpp, "phi4"} in results
  end

  test "unknown backend returns error" do
    assert {:error, msg} = CommandDispatch.parse("/llm route default=badbackend:model")
    assert msg =~ "unknown backend"
    assert msg =~ "badbackend"
  end

  test "backend prefix with empty model string returns error" do
    assert {:error, msg} = CommandDispatch.parse("/llm route default=openai:")
    assert msg =~ "cannot be empty"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/tui/command_dispatch_test.exs 2>&1 | tail -5
```

Expected: 5 failures on the new tests.

- [ ] **Step 3: Update `lib/shem/tui/command_dispatch.ex`**

Make four changes:

**1. Update `@spec`** — change line 13:

```elixir
| {:llm_route, [{atom(), :llama_cpp | :ollama | :openai | :anthropic, String.t()}]}
```

**2. Add `@known_backends` module attribute** — add after the `@spec` block, before `def parse(""), do:`:

```elixir
@known_backends ~w[llama_cpp ollama openai anthropic]
```

**3. Replace the `["llm", "route" | pair_parts]` clause** (lines 69–83) with:

```elixir
["llm", "route" | pair_parts] when pair_parts != [] ->
  valid_tokens =
    pair_parts
    |> Enum.map(&String.split(&1, "=", parts: 2))
    |> Enum.filter(&match?([_, _], &1))
    |> Enum.reject(fn [k, v] -> String.trim(k) == "" or String.trim(v) == "" end)

  result =
    Enum.reduce_while(valid_tokens, {:ok, []}, fn [k, v], {:ok, acc} ->
      case parse_route_pair(String.trim(k), String.trim(v)) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)

  case result do
    {:ok, []} -> {:error, "usage: /llm route <role>=<backend>:<model> or <role>=<model>"}
    {:ok, pairs} -> {:llm_route, Enum.reverse(pairs)}
    {:error, msg} -> {:error, msg}
  end

["llm", "route"] ->
  {:error, "usage: /llm route <role>=<backend>:<model> or <role>=<model>"}
```

**4. Add `parse_route_pair/2` private helper** — add at the bottom of the module, before the final `end`:

```elixir
@known_backends_str Enum.join(@known_backends, ", ")

defp parse_route_pair(role_str, value) do
  # String.to_atom is intentional: routing role atoms are user-defined and
  # may not exist in the atom table yet. This is safe for a trusted local TUI.
  role = String.to_atom(role_str)

  case String.split(value, ":", parts: 2) do
    [backend_str, model_str] when model_str != "" ->
      if backend_str in @known_backends do
        {:ok, {role, String.to_atom(backend_str), model_str}}
      else
        {:error,
         "unknown backend: #{backend_str} — valid: #{@known_backends_str}"}
      end

    [_, ""] ->
      {:error, "model cannot be empty after ':'"}

    [_] ->
      {:ok, {role, :llama_cpp, value}}
  end
end
```

**Note:** The existing bare-model tests (`reasoning=phi4`) still pass because values without `:` fall through to the `[_]` clause and return `{:ok, {role, :llama_cpp, value}}` unchanged.

- [ ] **Step 4: Run command_dispatch tests to verify they pass**

```bash
cd /home/philip/Downloads/_project/shem && mix test test/shem/tui/command_dispatch_test.exs 2>&1 | tail -5
```

Expected: all 42 tests pass (37 existing + 5 new).

- [ ] **Step 5: Run full suite to check for regressions**

```bash
cd /home/philip/Downloads/_project/shem && mix test 2>&1 | tail -5
```

Expected: 550 passed.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/command_dispatch.ex test/shem/tui/command_dispatch_test.exs
git commit -m "feat: CommandDispatch — backend:model syntax for /llm route"
```

---

## Task 5: Config Update

**Files:**
- Modify: `config/dev.exs`

### Background

No new required config keys — API keys come from env vars resolved inside the transports. Add a commented example block in `dev.exs` so cloud routing is discoverable. The comment goes directly inside the `llm_routes` map.

- [ ] **Step 1: Update `config/dev.exs`**

Find the `llm_routes` key in `config/dev.exs` and update it to:

```elixir
llm_routes: %{
  default: {:llama_cpp, "qwen3.6-27b-uncensored-hauhaucs-balanced"}
  # Cloud backends (set env vars first):
  #   OPENAI_API_KEY=sk-...    then: /llm route default=openai:gpt-4o
  #   ANTHROPIC_API_KEY=sk-... then: /llm route default=anthropic:claude-sonnet-4-6
},
```

- [ ] **Step 2: Verify config compiles cleanly**

```bash
cd /home/philip/Downloads/_project/shem && mix compile 2>&1 | tail -5
```

Expected: no errors.

- [ ] **Step 3: Run full suite one final time**

```bash
cd /home/philip/Downloads/_project/shem && mix test 2>&1 | tail -5
```

Expected: 550 passed, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add config/dev.exs
git commit -m "docs: dev.exs — add commented cloud LLM route examples"
```
