# Phase 19 — Structured LLM Messages Design

## Goal

Evolve `Shem.LLM.Request` to carry structured `system` and `messages` fields alongside the existing `prompt` string. Cloud transports (OpenAI, Anthropic) use the structured fields natively; local transports (LlamaCpp, Ollama) continue using `prompt` unchanged. Full backward compatibility — no existing tests break.

---

## Context

Currently `Shem.LLM.Request` carries a single `prompt: String.t()` field. `Agent.Turn.build_prompt/3` concatenates system prompt, tool manifest, and conversation history into one string. Cloud transports then wrap this string as a single user message: `[%{"role" => "user", "content" => prompt}]`. This works but loses the semantic structure — the cloud model can't distinguish system instructions from conversation history.

This phase adds structured fields to `Request`, wires `Agent.Turn.step/4` to populate them, and updates `OpenAITransport` and `AnthropicTransport` to use them when present.

---

## Design

### `Shem.LLM.Request` Struct

Add two optional fields. `prompt` stays — local transports use it unchanged.

```elixir
defstruct [:prompt, :model, :session_id, :system, :messages, options: %{}]

@type message :: %{role: :user | :assistant | :tool, content: String.t()}

@type t :: %__MODULE__{
  prompt: String.t(),
  model: atom(),
  session_id: term(),
  options: map(),
  system: String.t() | nil,
  messages: [message()] | nil
}
```

---

### `Agent.Turn` Changes

`build_prompt/3` is **unchanged** — it still returns a string. Existing callers and tests are unaffected.

A new `build_request/4` is added:

```elixir
@spec build_request(atom(), String.t(), [map()], [map()]) :: Request.t()
def build_request(model, system_prompt, tools_manifest, history) do
  prompt = build_prompt(system_prompt, tools_manifest, history)
  messages = build_messages(tools_manifest, history)
  %Request{
    prompt: prompt,
    model: model,
    system: system_prompt,
    messages: messages
  }
end
```

`build_messages/2` converts the history list into structured message maps:

```elixir
defp build_messages(tools_manifest, history) do
  tool_line = fn manifest ->
    manifest
    |> Enum.map(fn %{name: name, description: desc} -> "- #{name}: #{desc}" end)
    |> Enum.join("\n")
  end

  tool_header =
    if tools_manifest == [] do
      []
    else
      [%{role: :user, content: "Available tools:\n#{tool_line.(tools_manifest)}"}]
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

`step/4` is updated: replace `%Request{prompt: build_prompt(...), model: config.model}` with `build_request(config.model, system_prompt, tools_manifest, history)`.

---

### Transport Behaviour

| Transport | Behaviour |
|---|---|
| `LlamaCppTransport` | Uses `request.prompt` — unchanged |
| `OllamaTransport` | Uses `request.prompt` — unchanged |
| `OpenAITransport` | Uses `request.messages` + `request.system` when present; falls back to `[%{"role" => "user", "content" => request.prompt}]` |
| `AnthropicTransport` | Uses `request.messages` + `request.system` when present; same fallback |

**OpenAI structured request body:**

```json
{
  "model": "<model_string>",
  "messages": [
    {"role": "system", "content": "<system>"},
    {"role": "user",      "content": "Available tools:\n- shell: ..."},
    {"role": "user",      "content": "<first user turn>"},
    {"role": "assistant", "content": "<first assistant turn>"},
    ...
  ],
  "max_tokens": 512
}
```

System prompt becomes a `{"role": "system"}` message prepended to the list. Tool manifest header is a `user` message. History entries map directly. `:tool` role maps to `"user"` (tool results are fed back as user context).

**Anthropic structured request body:**

```json
{
  "model": "<model_string>",
  "system": "<system_prompt>",
  "messages": [
    {"role": "user",      "content": "Available tools:\n- shell: ..."},
    {"role": "user",      "content": "<first user turn>"},
    {"role": "assistant", "content": "<first assistant turn>"},
    ...
  ],
  "max_tokens": 512
}
```

Anthropic has a top-level `"system"` field separate from `messages`. History mapping is identical to OpenAI.

**Fallback (both transports):** If `request.messages` is `nil`, use the existing single-message wrapping:

```elixir
messages =
  case request.messages do
    nil -> [%{"role" => "user", "content" => request.prompt}]
    msgs -> format_messages(msgs, request.system)
  end
```

This means hand-constructed `%Request{prompt: "...", model: :default}` calls (test stubs, `Shem.LLM.complete/1` direct callers) continue to work without changes.

---

## File Map

| File | Action |
|---|---|
| `lib/shem/llm/request.ex` | Modify — add `system`, `messages` fields and `message()` type |
| `lib/shem/agent/turn.ex` | Modify — add `build_request/4` and `build_messages/2`; update `step/4` |
| `lib/shem/llm/middleware/openai_transport.ex` | Modify — use structured messages when present |
| `lib/shem/llm/middleware/anthropic_transport.ex` | Modify — use structured messages + top-level system when present |
| `test/shem/agent/turn_test.exs` | Modify — add tests for `build_request/4` and `build_messages/2` |
| `test/shem/llm/middleware/openai_transport_test.exs` | Modify — add test for structured messages path |
| `test/shem/llm/middleware/anthropic_transport_test.exs` | Modify — add test for structured messages path |

---

## Testing Strategy

- `build_prompt/3` tests pass unchanged (it's not modified)
- `build_request/4` tests: verify `prompt` is populated (via `build_prompt`), `system` matches the input, `messages` has the right structure for a known history list
- `build_messages/2` tests: empty tools manifest produces no tool header; `:tool` role maps to `%{role: :user}`
- Transport tests: add one test per transport for the structured messages path (system + messages present → correct JSON body shape); existing tests exercise the fallback path
- Full agent loop test: agent `step/4` produces a `Request` with non-nil `messages` when history is non-empty

---

## Future Work

- `:tool` role could carry structured tool-result metadata (tool name, tool id) rather than just a string. Deferred until tool-calling APIs are used natively.
- Streaming with structured messages (chunked SSE responses from OpenAI/Anthropic).
- Multi-turn system prompt evolution (system prompt that updates between turns based on agent state).
