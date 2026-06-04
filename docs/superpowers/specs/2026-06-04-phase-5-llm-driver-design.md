# Phase 5: LLM Driver Design

**Date:** 2026-06-04
**Status:** Approved
**Scope:** Middleware pipeline for LLM calls — Ollama transport, budget enforcement, event log integration, stub transport for tests.

---

## 1. Context and Goals

Phase 4b shipped a complete MCP client layer. Phase 5 gives Shem the ability to *drive* LLMs directly — not just receive connections from them. This is the foundational increment: nothing in the agent loop works until Shem can call a model, track what it spent, and record what happened.

Phase 5 is intentionally scoped to the driver layer only:
- Middleware pipeline with Ollama as the first transport
- Token budget enforcement (global hard limit + soft warning)
- Automatic event log integration at the call boundary
- Stub transport for deterministic testing

Timeline/replay work (mocking LLM calls from the event log, fork/branching) is **Phase 6**. Per-agent budget allocation by the orchestrator is a future concern — the data model is designed to accommodate it.

---

## 2. Architecture

Every LLM call flows through a middleware pipeline built per-call from config. The pipeline config (which middleware modules to use) is immutable at runtime — set at startup and never changed.

```
caller
  │
  ▼
Shem.LLM.complete/1 or stream/2    ← public API, single entry point
  │
  ▼
[BudgetCheck]       ← halts if global budget exhausted; soft warning at threshold
  │
  ▼
[EventLogger]       ← appends :llm_call_started to event log
  │
  ▼
[OllamaTransport]   ← HTTP POST to Ollama/llama-server, returns %Response{}
  │
  ▼
[EventLogger]       ← appends :llm_call_completed (tokens_used, latency_ms)
  │
  ▼
[BudgetCheck]       ← deducts tokens; skips deduction on error
  │
  ▼
{:ok, %Response{}} | {:error, reason}
```

`EventLogger` and `BudgetCheck` each run on both sides of the transport via the standard middleware double-pass. Stateless middleware modules call into `BudgetServer` (a GenServer) for budget state — they hold no state themselves.

The pipeline is assembled as a right-fold over the middleware list, building a nested `next` function chain. The terminal transport never calls `next`; the innermost fallback function (`fn _ -> {:error, :no_terminal} end`) should never fire.

---

## 3. Components

### 3.1 Core Structs

```elixir
%Shem.LLM.Request{
  prompt:     String.t(),
  model:      atom(),          # e.g. :llama3 — resolved to Ollama string via config
  options:    map(),           # temperature, max_tokens, etc. — passed through to transport
  session_id: String.t()       # injected by public API if not set by caller
}

%Shem.LLM.Response{
  content:     String.t(),
  tokens_used: non_neg_integer(),
  model:       atom(),
  latency_ms:  non_neg_integer()
}
```

### 3.2 `Shem.LLM.Middleware` Behaviour

```elixir
@callback call(request :: Request.t(), next :: (Request.t() -> pipeline_result())) ::
  {:ok, Response.t()} | {:error, term()}
```

Each middleware receives the request and a `next` function. Calling `next.(request)` passes control downstream. Returning `{:error, reason}` without calling `next` halts the pipeline.

### 3.3 Middleware Modules

**`Shem.LLM.Middleware.BudgetCheck`**
- Before: calls `BudgetServer.check/0`. Returns `{:error, :budget_exhausted}` if the hard limit is reached (appends `:budget_exhausted` event before halting). Appends `:budget_soft_warning` event and sets `soft_warned? = true` at threshold — fires once per session.
- After: calls `BudgetServer.deduct/1` with `response.tokens_used`. Skips deduction on `{:error, _}`.

**`Shem.LLM.Middleware.EventLogger`**
- Before: appends `:llm_call_started` (model, session_id, timestamp) to event log.
- After: appends `:llm_call_completed` (tokens_used, latency_ms) on success; `:llm_call_failed` (reason) on error.

**`Shem.LLM.Middleware.OllamaTransport`**
- Terminal middleware — never calls `next`.
- POSTs to `http://localhost:11434/api/generate` (host/port from config).
- Parses JSON response into `%Response{}`.
- Returns `{:error, {:transport, reason}}` on HTTP failure; `{:error, {:parse_error, raw_body}}` on unexpected response shape.

### 3.4 `Shem.LLM.BudgetServer`

GenServer supervised under the application tree alongside `MCP.Client.Supervisor`. State:

```elixir
%{
  global_limit:   non_neg_integer(),   # from config
  soft_threshold: float(),             # fraction, default 0.8
  tokens_used:    non_neg_integer(),   # accumulator
  soft_warned?:   boolean()
}
```

Resets on session start — `reset/0` is called explicitly by the session machinery when a new session is created. Public calls: `check/0`, `deduct/1`, `reset/0`, `status/0`.

### 3.5 `Shem.LLM.StubTransport`

Terminal middleware for tests. Backed by `Shem.LLM.StubTransport.Server` — a GenServer holding a per-test response queue.

- `push_response/1` — enqueues a canned `{:ok, %Response{}}` or `{:error, reason}`
- `call/2` — pops the front of the queue; falls back to a configurable default response when empty
- `calls/0` — returns list of all `%Request{}` received, for assertion

Started per-test via `start_supervised/1`. No shared state between tests.

### 3.6 `Shem.LLM` Public API

```elixir
Shem.LLM.complete(request)            # {:ok, %Response{}} | {:error, reason}
Shem.LLM.stream(request, callback)    # streams chunks via callback/1; returns {:ok, %Response{}}
```

`complete/1` assembles the pipeline from config and reduces over it. `stream/2` is in scope but `StubTransport` returns a single chunk — full streaming test support deferred to Phase 6.

Session ID is injected from the current session if not set on the request.

---

## 4. Data Flow

**Model name resolution:** `request.model` (atom) is resolved to an Ollama model string via config:

```elixir
config :shem, llm_models: %{llama3: "llama3:latest", phi4: "phi4:30b"}
```

Unknown atoms fall back to `Atom.to_string(atom)` with a logged warning. Future routing middleware will intercept here to select the model based on task class — this is where the llama.cpp adapter and multi-model routing will hook in.

**Session correlation:** `request.session_id` threads through all event log entries, tying LLM calls to the session timeline.

**Pipeline assembly:** Built once per call from `Application.get_env(:shem, :llm_pipeline, [BudgetCheck, EventLogger, OllamaTransport])`. The list is right-folded into a nested closure.

---

## 5. Error Handling

| Condition | Behaviour |
|---|---|
| Hard budget limit reached | `BudgetCheck` returns `{:error, :budget_exhausted}` before transport; `:budget_exhausted` event appended |
| Soft budget threshold crossed | Warning event appended; `soft_warned?` set; call continues |
| Ollama unreachable / HTTP error | `{:error, {:transport, reason}}`; no token deduction |
| Malformed Ollama response | `{:error, {:parse_error, raw_body}}`; raw body in event log |
| Any middleware error | Short-circuits chain; post-`next` logic in upstream middleware still runs (pattern-matches on `{:error, _}`) |

Agent snapshot / continuation-plan behavior on budget exhaustion is a Phase 6 concern.

---

## 6. Configuration

```elixir
# config/dev.exs
config :shem,
  llm_pipeline:       [Shem.LLM.Middleware.BudgetCheck, Shem.LLM.Middleware.EventLogger, Shem.LLM.Middleware.OllamaTransport],
  llm_ollama_url:     "http://localhost:11434",
  llm_models:         %{default: "llama3:latest"},
  llm_budget_limit:   500_000,
  llm_soft_threshold: 0.8

# config/test.exs
config :shem,
  llm_pipeline:       [Shem.LLM.Middleware.BudgetCheck, Shem.LLM.Middleware.EventLogger, Shem.LLM.StubTransport],
  llm_budget_limit:   100_000,
  llm_soft_threshold: 0.8
```

---

## 7. Testing

**Coverage targets:**

- `BudgetServer` — hard limit halt, soft warning fires once, token deduction, reset on session start
- `BudgetCheck` middleware — halts before transport on exhaustion, skips deduction on error, passes through on success
- `EventLogger` middleware — started/completed/failed events with correct fields, session_id correlation
- `OllamaTransport` — HTTP happy path, unreachable host, malformed JSON, unknown model atom fallback
- `StubTransport` — response queue pop order, empty queue fallback, call recording
- `Shem.LLM` public API — pipeline assembly from config, `complete/1` end-to-end with stub, session_id injection

**Integration smoke test:** `scripts/smoke_llm.exs` — calls `Shem.LLM.complete/1` against a live Ollama instance, prints response and token count, verifies event log entries. Consistent with Phase 4's `scripts/smoke_mcp.exs` pattern.

---

## 8. Future Directions

- **`Shem.LLM.LlamaCppAdapter`** — `llama-server` exposes an OpenAI-compatible HTTP API; this adapter is structurally identical to `OllamaTransport`. User runs a 30B model on a GTX 4070 locally.
- **Routing middleware** — a `RouterMiddleware` plug that selects transport by task class (e.g. `:reasoning → phi4:30b`, `:tools → qwen:7b`), configured via TUI slash commands (`/llm route reasoning=phi4:30b`).
- **Per-agent budget allocation** — orchestrator carves per-agent slots from the global pool; `BudgetServer` data model is designed to accommodate this without a rewrite.
- **`Shem.LLM.BumblebeeTransport`** — BEAM-native inference via Nx/EXLA; deferred until GPU/EXLA setup is validated.

---

## 9. Out of Scope (Phase 5)

- LLM call mocking from event log replay (Phase 6)
- Timeline fork / branching (Phase 6)
- Per-agent budget allocation (Phase 6+)
- Full streaming test support (Phase 6)
- K8s pod executor backend (Phase 4c / Phase 6)
- Bumblebee transport (future)
- Multi-model routing (future)
