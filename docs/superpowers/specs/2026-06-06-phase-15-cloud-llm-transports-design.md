# Phase 15 — Cloud LLM Transports Design

## Goal

Add OpenAI and Anthropic as first-class LLM backends, wired into the existing `RouterTransport` pipeline. Enable runtime routing to cloud models via TUI (`/llm route default=openai:gpt-4o`) alongside the existing local transports.

---

## Context

Phase 14 introduced `Shem.LLM.Router` and `RouterTransport` — a runtime-mutable route table that maps model atoms (`:default`, `:reasoning`, `:tools`) to `{backend_key, model_string}` pairs, resolved at call time by the terminal middleware. The two existing backends are `:llama_cpp` and `:ollama`.

Phase 15 adds `:openai` and `:anthropic` as backend atoms, each backed by a new transport module.

---

## Design

### Prompt Format

`Agent.Turn.build_prompt/3` produces a single string embedding system instructions, tool manifest, and conversation history. Both new transports wrap this string as a single user message:

```json
{"role": "user", "content": "<full prompt string>"}
```

No changes to `Shem.LLM.Request`, `Shem.LLM.Response`, or `Agent.Turn`. This is intentionally minimal — see Future Work for the structured-messages evolution.

---

### Transport Modules

Both modules implement `Shem.LLM.Middleware` and follow the opts-injection pattern established by `LlamaCppTransport`: all configuration comes from opts with env var / application config defaults. Tests inject `http_post_fn:` — no live API calls anywhere.

#### `Shem.LLM.Middleware.OpenAITransport`

- **Endpoint:** `{base_url}/v1/chat/completions` (default `base_url`: `"https://api.openai.com"`)
- **Auth:** `Authorization: Bearer <key>` header
- **Key resolution:** `opts[:api_key]` → `System.get_env("OPENAI_API_KEY", "")`
- **Request body:**
  ```json
  {
    "model": "<model_string>",
    "messages": [{"role": "user", "content": "<prompt>"}],
    "max_tokens": <N>
  }
  ```
- **Response parse:** `choices[0].message.content` + `usage.total_tokens`
- **`base_url:` opt** makes this transport work with any OpenAI-compatible endpoint (e.g. LM-Studio's `/v1/chat/completions`)

#### `Shem.LLM.Middleware.AnthropicTransport`

- **Endpoint:** `https://api.anthropic.com/v1/messages` (fixed, no base_url opt)
- **Auth:** `x-api-key: <key>` + `anthropic-version: 2023-06-01` headers
- **Key resolution:** `opts[:api_key]` → `System.get_env("ANTHROPIC_API_KEY", "")`
- **Request body:**
  ```json
  {
    "model": "<model_string>",
    "messages": [{"role": "user", "content": "<prompt>"}],
    "max_tokens": <N>
  }
  ```
- **Response parse:** `content[0].text` + `usage.input_tokens + usage.output_tokens`

#### Shared error map (both transports)

| HTTP status | Return value |
|---|---|
| 200 | `{:ok, %Response{}}` |
| 401 | `{:error, {:transport, :unauthorized}}` |
| 429 | `{:error, {:transport, :rate_limited}}` |
| other | `{:error, {:transport, {:http_error, status}}}` |
| network | `{:error, {:transport, reason}}` |
| bad body | `{:error, {:parse_error, raw_body}}` |

#### Opts reference (both transports)

| Opt | Default | Purpose |
|---|---|---|
| `model_string:` | `"gpt-4o"` / `"claude-sonnet-4-6"` | Model name string, injected by RouterTransport |
| `api_key:` | env var | API key; injected in tests |
| `http_post_fn:` | `&Req.post/2` | HTTP client; injected in tests |
| `timeout_ms:` | `Application.get_env(:shem, :llm_timeout_ms, 120_000)` | Request timeout |
| `base_url:` | `"https://api.openai.com"` | OpenAI only; override for compatible endpoints |

---

### Router Update

`Shem.LLM.Router` adds two entries to `@backend_modules`:

```elixir
@backend_modules %{
  llama_cpp: Shem.LLM.Middleware.LlamaCppTransport,
  ollama:    Shem.LLM.Middleware.OllamaTransport,
  openai:    Shem.LLM.Middleware.OpenAITransport,
  anthropic: Shem.LLM.Middleware.AnthropicTransport
}
```

The existing `{:error, {:unknown_backend, key}}` path in `build_transport/2` requires no changes.

One new test: `set_route(:default, :openai, "gpt-4o")` → `resolve(:default)` returns `{OpenAITransport, [model_string: "gpt-4o"]}`.

---

### CommandDispatch — `backend:model` Syntax

`/llm route` pairs now accept an optional `backend:` prefix on the value:

```
/llm route default=openai:gpt-4o           → {:default, :openai, "gpt-4o"}
/llm route reasoning=anthropic:claude-sonnet-4-6 → {:reasoning, :anthropic, "claude-sonnet-4-6"}
/llm route tools=phi4                       → {:tools, :llama_cpp, "phi4"}  ← backward compat
```

**Parse rule:** split value on first `:`. If two parts result, the left part is the backend string; validate it against the known set `["llama_cpp", "ollama", "openai", "anthropic"]`. Unknown backend → `{:error, "unknown backend: foo — valid: llama_cpp, ollama, openai, anthropic"}`. If no `:` in value, backend defaults to `:llama_cpp` (existing behaviour unchanged).

**`@spec` update:** `{atom(), :llama_cpp | :ollama | :openai | :anthropic, String.t()}` in the `{:llm_route, [...]}` return type.

New test cases: valid `backend:model` pair, unknown backend error, mixed batch (some with prefix, some without), empty model string after prefix → existing empty-value error.

---

### Config

No new config keys. API keys are environment variables only. `config/dev.exs` gets a commented example block for discoverability:

```elixir
llm_routes: %{
  default: {:llama_cpp, "qwen3.6-27b-uncensored-hauhaucs-balanced"}
  # Cloud examples (requires OPENAI_API_KEY / ANTHROPIC_API_KEY env vars):
  # default: {:openai, "gpt-4o"},
  # reasoning: {:anthropic, "claude-sonnet-4-6"},
}
```

---

## File Map

| File | Action |
|---|---|
| `lib/shem/llm/middleware/openai_transport.ex` | Create |
| `lib/shem/llm/middleware/anthropic_transport.ex` | Create |
| `test/shem/llm/middleware/openai_transport_test.exs` | Create |
| `test/shem/llm/middleware/anthropic_transport_test.exs` | Create |
| `lib/shem/llm/router.ex` | Modify — add `:openai`, `:anthropic` to `@backend_modules` |
| `test/shem/llm/router_test.exs` | Modify — 1 new test |
| `lib/shem/tui/command_dispatch.ex` | Modify — `backend:model` parse + updated `@spec` |
| `test/shem/tui/command_dispatch_test.exs` | Modify — ~4 new tests |
| `config/dev.exs` | Modify — commented cloud route examples |

---

## Testing Strategy

All tests use `http_post_fn:` injection. No live API calls. Each transport test file covers:

1. Successful 200 → correct `%Response{}` (content, tokens_used, latency_ms > 0)
2. 401 → `{:error, {:transport, :unauthorized}}`
3. 429 → `{:error, {:transport, :rate_limited}}`
4. Non-200 (e.g. 500) → `{:error, {:transport, {:http_error, 500}}}`
5. Malformed body → `{:error, {:parse_error, _}}`

---

## Future Work

- **Structured messages (Phase N):** Evolve `Shem.LLM.Request` to carry `system: String.t()` and `messages: [%{role: atom(), content: String.t()}]` fields. Transports that support structured messages use them; `LlamaCppTransport`/`OllamaTransport` fall back to single-string completion. Requires changes to `Agent.Turn.build_prompt/3` and `Agent.Turn.step/4`.
- **OpenCode Responses API (Phase N+1):** The OpenCode platform uses `/v1/responses` (stateful, agentic) rather than `/v1/chat/completions`. This API is stateful by design and conflicts with Shem's stateless-per-call transport model. A proper implementation requires a dedicated `ResponsesTransport` and a design for stateful session tracking.
