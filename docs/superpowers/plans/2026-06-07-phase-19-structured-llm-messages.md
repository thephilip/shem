# Phase 19 — Structured LLM Messages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Evolve `Shem.LLM.Request` to carry structured `system` and `messages` fields so cloud transports (OpenAI, Anthropic) can use native message-array APIs instead of wrapping everything in a single user message.

**Architecture:** Add two optional fields (`system`, `messages`) to `Request`; add `build_request/4` in `Agent.Turn` that populates all fields and update `step/4` to call it; update `OpenAITransport` and `AnthropicTransport` to use structured fields when present, falling back to `prompt` wrapping when nil. Local transports (`LlamaCpp`, `Ollama`) are unchanged.

**Tech Stack:** Elixir/OTP, ExUnit. No new dependencies.

---

## File Map

| File | Action |
|---|---|
| `lib/shem/llm/request.ex` | Modify — add `system`, `messages` fields and `message()` type |
| `lib/shem/agent/turn.ex` | Modify — add `build_request/4` and private `build_messages/2`; update `step/4` |
| `lib/shem/llm/middleware/openai_transport.ex` | Modify — use structured messages when present, fall back to prompt |
| `lib/shem/llm/middleware/anthropic_transport.ex` | Modify — use structured messages + top-level system when present |
| `test/shem/agent/turn_test.exs` | Modify — add `build_request/4` describe block |
| `test/shem/llm/middleware/openai_transport_test.exs` | Modify — add structured messages test |
| `test/shem/llm/middleware/anthropic_transport_test.exs` | Modify — add structured messages test |

---

## Task 1: Extend `Shem.LLM.Request`

**Files:**
- Modify: `lib/shem/llm/request.ex`

Add `system` and `messages` optional fields and a `message()` type alias. `@enforce_keys` stays — backward compat requires `prompt` and `model` to always be set.

- [ ] **Step 1: Replace the file contents**

`lib/shem/llm/request.ex`:

```elixir
defmodule Shem.LLM.Request do
  @enforce_keys [:prompt, :model]
  defstruct [:prompt, :model, :session_id, :system, :messages, options: %{}]

  @type message :: %{role: :user | :assistant | :tool, content: String.t()}

  @type t :: %__MODULE__{
          prompt: String.t(),
          model: atom(),
          options: map(),
          session_id: String.t() | nil,
          system: String.t() | nil,
          messages: [message()] | nil
        }
end
```

- [ ] **Step 2: Verify existing tests still pass**

```bash
cd /home/philip/Downloads/_project/shem
mix test test/shem/llm/ 2>&1 | tail -8
```

Expected: all existing LLM tests pass, no failures.

- [ ] **Step 3: Commit**

```bash
git add lib/shem/llm/request.ex
git commit -m "feat: LLM.Request — add system and messages fields"
```

---

## Task 2: Add `build_request/4` and update `step/4` in `Agent.Turn`

**Files:**
- Modify: `lib/shem/agent/turn.ex`
- Modify: `test/shem/agent/turn_test.exs`

`build_prompt/3` is unchanged. `build_request/4` calls it for the `prompt` field, and separately calls `build_messages/2` to produce the structured messages list. `step/4` is updated to call `build_request/4`.

- [ ] **Step 1: Write the failing tests first**

Add this describe block to `test/shem/agent/turn_test.exs` before the closing `end`:

```elixir
  describe "build_request/4" do
    @req_manifest [
      %{name: "list_tools", description: "List tools.", source: :builtin},
      %{name: "run_code", description: "Run code.", source: :builtin}
    ]

    test "prompt field is populated via build_prompt" do
      request = Turn.build_request(:default, "Be helpful.", @req_manifest, [%{role: :user, content: "task"}])
      assert request.prompt =~ "Be helpful."
      assert request.prompt =~ "task"
    end

    test "system field matches the system_prompt argument" do
      request = Turn.build_request(:default, "You are precise.", @req_manifest, [%{role: :user, content: "task"}])
      assert request.system == "You are precise."
    end

    test "model field matches the model argument" do
      request = Turn.build_request(:openai, "sys", @req_manifest, [%{role: :user, content: "task"}])
      assert request.model == :openai
    end

    test "messages contains tool header when manifest is non-empty" do
      request = Turn.build_request(:default, "sys", @req_manifest, [%{role: :user, content: "task"}])
      tool_msg = hd(request.messages)
      assert tool_msg.role == :user
      assert tool_msg.content =~ "list_tools"
      assert tool_msg.content =~ "run_code"
    end

    test "messages has no tool header when manifest is empty" do
      request = Turn.build_request(:default, "sys", [], [%{role: :user, content: "task"}])
      assert Enum.all?(request.messages, fn m -> not String.contains?(m.content, "Available tools") end)
    end

    test "history :tool role maps to :user in messages" do
      history = [
        %{role: :user, content: "task"},
        %{role: :assistant, content: "calling"},
        %{role: :tool, content: "Tool result: 42"}
      ]
      request = Turn.build_request(:default, "sys", [], history)
      roles = Enum.map(request.messages, & &1.role)
      assert :tool not in roles
      assert Enum.count(request.messages, &(&1.role == :user)) == 2
    end

    test "history :assistant role preserved in messages" do
      history = [
        %{role: :user, content: "hi"},
        %{role: :assistant, content: "hello"}
      ]
      request = Turn.build_request(:default, "sys", [], history)
      assert Enum.any?(request.messages, &(&1.role == :assistant and &1.content == "hello"))
    end
  end
```

- [ ] **Step 2: Run to verify tests fail**

```bash
mix test test/shem/agent/turn_test.exs 2>&1 | tail -10
```

Expected: failures with `undefined function Turn.build_request/4`.

- [ ] **Step 3: Implement `build_request/4` and `build_messages/2` in `turn.ex`**

Add after the `build_prompt/3` function (before `step/4`) in `lib/shem/agent/turn.ex`:

```elixir
  @spec build_request(atom(), String.t(), [map()], [map()]) :: Request.t()
  def build_request(model, system_prompt, tools_manifest, history) do
    prompt = build_prompt(system_prompt, tools_manifest, history)
    messages = build_messages(tools_manifest, history)
    %Request{prompt: prompt, model: model, system: system_prompt, messages: messages}
  end

  defp build_messages(tools_manifest, history) do
    tool_header =
      if tools_manifest == [] do
        []
      else
        lines =
          tools_manifest
          |> Enum.map(fn %{name: name, description: desc} -> "- #{name}: #{desc}" end)
          |> Enum.join("\n")
        [%{role: :user, content: "Available tools:\n#{lines}"}]
      end

    history_messages =
      Enum.map(history, fn
        %{role: :user, content: c}      -> %{role: :user, content: c}
        %{role: :assistant, content: c} -> %{role: :assistant, content: c}
        %{role: :tool, content: c}      -> %{role: :user, content: c}
      end)

    tool_header ++ history_messages
  end
```

- [ ] **Step 4: Update `step/4` to call `build_request/4`**

In `lib/shem/agent/turn.ex`, replace the `step/4` body:

Old:
```elixir
  def step(%Config{} = config, session_id, history, tools_manifest) do
    prompt = build_prompt(config.system_prompt, tools_manifest, history)
    request = %Request{prompt: prompt, model: config.model, session_id: session_id}
```

New:
```elixir
  def step(%Config{} = config, session_id, history, tools_manifest) do
    request =
      config.model
      |> build_request(config.system_prompt, tools_manifest, history)
      |> Map.put(:session_id, session_id)
```

- [ ] **Step 5: Run all turn tests**

```bash
mix test test/shem/agent/turn_test.exs 2>&1 | tail -10
```

Expected: all tests pass, no failures.

- [ ] **Step 6: Run full suite to check for regressions**

```bash
mix test 2>&1 | tail -8
```

Expected: same number of tests as before plus the new ones, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/agent/turn.ex test/shem/agent/turn_test.exs
git commit -m "feat: Agent.Turn — build_request/4 with structured messages; step/4 updated"
```

---

## Task 3: Update `OpenAITransport` — structured messages

**Files:**
- Modify: `lib/shem/llm/middleware/openai_transport.ex`
- Modify: `test/shem/llm/middleware/openai_transport_test.exs`

When `request.messages` is non-nil, build the messages array from it (prepending a system message if `request.system` is set). Fall back to `[%{"role" => "user", "content" => request.prompt}]` when nil.

- [ ] **Step 1: Write the failing test**

Add to the end of `test/shem/llm/middleware/openai_transport_test.exs` (inside the module, before the closing `end`):

```elixir
  describe "call/3 — structured messages" do
    test "uses request.messages array and prepends system message when present" do
      messages = [
        %{role: :user, content: "Available tools:\n- shell: Run shell"},
        %{role: :user, content: "What is 2+2?"},
        %{role: :assistant, content: "Let me compute."}
      ]
      request = %Request{
        prompt: "fallback prompt",
        model: :default,
        system: "Be concise.",
        messages: messages
      }

      mock = fn _url, opts ->
        body = opts[:json]
        msgs = body["messages"]
        assert hd(msgs) == %{"role" => "system", "content" => "Be concise."}
        assert Enum.any?(msgs, &(&1["content"] == "What is 2+2?"))
        assert Enum.any?(msgs, &(&1["role"] == "assistant"))
        {:ok, %{status: 200, body: success_body("4", 10)}}
      end

      opts = [api_key: "sk-test", http_post_fn: mock]
      assert {:ok, %Response{content: "4"}} = OpenAITransport.call(request, opts, nil)
    end

    test "falls back to prompt-wrap when request.messages is nil" do
      request = %Request{prompt: "hello", model: :default}

      mock = fn _url, opts ->
        msgs = opts[:json]["messages"]
        assert msgs == [%{"role" => "user", "content" => "hello"}]
        {:ok, %{status: 200, body: success_body("hi", 5)}}
      end

      opts = [api_key: "sk-test", http_post_fn: mock]
      assert {:ok, %Response{content: "hi"}} = OpenAITransport.call(request, opts, nil)
    end
  end
```

- [ ] **Step 2: Run to verify tests fail**

```bash
mix test test/shem/llm/middleware/openai_transport_test.exs 2>&1 | tail -10
```

Expected: 2 new failures (structured messages test fails; fallback test may pass).

- [ ] **Step 3: Update `OpenAITransport.call/3` to use structured messages**

In `lib/shem/llm/middleware/openai_transport.ex`, replace the `body` assignment (lines 17-21 of the current file) with:

```elixir
      messages =
        case request.messages do
          nil ->
            [%{"role" => "user", "content" => request.prompt}]

          msgs ->
            system_msgs =
              if request.system do
                [%{"role" => "system", "content" => request.system}]
              else
                []
              end

            formatted =
              Enum.map(msgs, fn %{role: role, content: content} ->
                %{"role" => to_string(role), "content" => content}
              end)

            system_msgs ++ formatted
        end

      body = %{
        "model" => model_string,
        "messages" => messages,
        "max_tokens" => max_tokens
      }
```

- [ ] **Step 4: Run OpenAI transport tests**

```bash
mix test test/shem/llm/middleware/openai_transport_test.exs 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Run full suite**

```bash
mix test 2>&1 | tail -8
```

Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/llm/middleware/openai_transport.ex test/shem/llm/middleware/openai_transport_test.exs
git commit -m "feat: OpenAITransport — use structured messages when present"
```

---

## Task 4: Update `AnthropicTransport` — structured messages + top-level system

**Files:**
- Modify: `lib/shem/llm/middleware/anthropic_transport.ex`
- Modify: `test/shem/llm/middleware/anthropic_transport_test.exs`

Anthropic's API accepts a top-level `"system"` field separate from `messages`. When `request.messages` is non-nil, use them and include `"system"` in the body when `request.system` is set.

- [ ] **Step 1: Write the failing test**

Add to `test/shem/llm/middleware/anthropic_transport_test.exs` (inside module, before closing `end`):

```elixir
  describe "call/3 — structured messages" do
    test "uses request.messages and top-level system field when present" do
      messages = [
        %{role: :user, content: "What is 2+2?"},
        %{role: :assistant, content: "Let me compute."}
      ]
      request = %Request{
        prompt: "fallback prompt",
        model: :default,
        system: "Be concise.",
        messages: messages
      }

      mock = fn _url, opts ->
        body = opts[:json]
        assert body["system"] == "Be concise."
        assert body["messages"] == [
          %{"role" => "user", "content" => "What is 2+2?"},
          %{"role" => "assistant", "content" => "Let me compute."}
        ]
        assert not Map.has_key?(hd(body["messages"]), "system")
        {:ok, %{status: 200, body: success_body("4", 5, 2)}}
      end

      opts = [api_key: "sk-ant-test", http_post_fn: mock]
      assert {:ok, %Response{content: "4"}} = AnthropicTransport.call(request, opts, nil)
    end

    test "falls back to prompt-wrap and no system field when request.messages is nil" do
      request = %Request{prompt: "hello", model: :default}

      mock = fn _url, opts ->
        body = opts[:json]
        assert body["messages"] == [%{"role" => "user", "content" => "hello"}]
        assert not Map.has_key?(body, "system")
        {:ok, %{status: 200, body: success_body("hi", 5, 2)}}
      end

      opts = [api_key: "sk-ant-test", http_post_fn: mock]
      assert {:ok, %Response{content: "hi"}} = AnthropicTransport.call(request, opts, nil)
    end
  end
```

- [ ] **Step 2: Run to verify tests fail**

```bash
mix test test/shem/llm/middleware/anthropic_transport_test.exs 2>&1 | tail -10
```

Expected: 2 new failures.

- [ ] **Step 3: Update `AnthropicTransport.call/3`**

In `lib/shem/llm/middleware/anthropic_transport.ex`, replace the `body` assignment (lines 17-21) with:

```elixir
      {body_messages, maybe_system} =
        case request.messages do
          nil ->
            {[%{"role" => "user", "content" => request.prompt}], nil}

          msgs ->
            formatted =
              Enum.map(msgs, fn %{role: role, content: content} ->
                %{"role" => to_string(role), "content" => content}
              end)

            {formatted, request.system}
        end

      base_body = %{
        "model" => model_string,
        "messages" => body_messages,
        "max_tokens" => max_tokens
      }

      body = if maybe_system, do: Map.put(base_body, "system", maybe_system), else: base_body
```

- [ ] **Step 4: Run Anthropic transport tests**

```bash
mix test test/shem/llm/middleware/anthropic_transport_test.exs 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Run full suite**

```bash
mix test 2>&1 | tail -8
```

Expected: 0 failures, test count increased by new tests across all four files.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/llm/middleware/anthropic_transport.ex test/shem/llm/middleware/anthropic_transport_test.exs
git commit -m "feat: AnthropicTransport — structured messages + top-level system when present"
```

---

## Self-Review Checklist

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| `system` and `messages` fields on `Request` | Task 1 |
| `message()` type alias | Task 1 |
| `build_request/4` public function | Task 2 |
| `build_messages/2` private; tool header; `:tool` → `:user` | Task 2 |
| `step/4` calls `build_request/4` | Task 2 |
| OpenAI: structured messages when present; system prepended as `{"role":"system"}` | Task 3 |
| OpenAI: fallback to `prompt` wrap when `messages` nil | Task 3 |
| Anthropic: structured messages when present; `system` in top-level field | Task 4 |
| Anthropic: fallback to `prompt` wrap; no `"system"` key when nil | Task 4 |
| `build_prompt/3` unchanged | Verified: not touched |
| LlamaCpp/Ollama unchanged | Verified: not in file map |

**No placeholders found.**

**Type consistency:**
- `build_request/4` returns `Request.t()` with `messages: [message()]` — atoms `:user`, `:assistant`, `:tool`
- `to_string(:user)` → `"user"`, `to_string(:assistant)` → `"assistant"` — correct for both API wire formats
- `:tool` role converted to `:user` in `build_messages/2` before reaching transport — transports never see `:tool` atom
