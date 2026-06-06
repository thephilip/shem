# Phase 14 — LLM Routing Layer Design

## Overview

Phase 14 adds agent-level LLM routing to Shem. Different named model slots (`:default`, `:reasoning`, `:tools`, etc.) resolve to different (backend, model_string) pairs at runtime. The route table is mutable via TUI commands without restarting the app.

The current pipeline uses a fixed terminal transport (`LlamaCppTransport`). This phase replaces it with a `RouterTransport` that dispatches to the correct backend based on `request.model`. All other middleware (budget, logging) is unchanged.

---

## Architecture

### 1. `Shem.LLM.Router`

GenServer holding the runtime route table.

**State:** `%{model_atom => {backend_key, model_string}}`
- `model_atom` — any atom: `:default`, `:reasoning`, `:tools`, or any user-defined name
- `backend_key` — `:llama_cpp` | `:ollama`
- `model_string` — the exact model identifier string passed to the transport

**Startup:** Reads initial routes from `Application.get_env(:shem, :llm_routes, %{})`. Must include a `:default` entry. Started unconditionally in `Application` alongside `Trust.Store`.

**Public API:**

```elixir
@spec resolve(atom()) :: {module(), keyword()} | {:error, :no_default}
def resolve(model_atom)
```

Returns `{transport_module, opts}` for the given atom. Falls back to `:default` if the atom is not in the table. Returns `{:error, :no_default}` only if `:default` itself is missing (misconfiguration).

```elixir
@spec set_route(atom(), :llama_cpp | :ollama, String.t()) :: :ok
def set_route(model_atom, backend_key, model_string)
```

Overwrites the route for `model_atom`. Safe to call at any time.

```elixir
@spec all() :: %{atom() => {:llama_cpp | :ollama, String.t()}}
def all()
```

Returns the full route table. Used by `/llm routes` to render current config.

**Backend resolution:** Maps `backend_key` to `{transport_module, base_opts}`:
- `:llama_cpp` → `{Shem.LLM.Middleware.LlamaCppTransport, []}`
- `:ollama` → `{Shem.LLM.Middleware.OllamaTransport, []}`

The resolved `opts` always include `model_string` as `[model: model_string]`, merged with base opts.

---

### 2. `Shem.LLM.Middleware.RouterTransport`

Replaces the static terminal transport in the pipeline. Implements `Shem.LLM.Middleware`.

```elixir
@impl true
def call(request, _opts, _next) do
  case Shem.LLM.Router.resolve(request.model) do
    {transport_module, opts} -> transport_module.call(request, opts, fn _ -> {:error, :no_next} end)
    {:error, reason} -> {:error, {:router, reason}}
  end
end
```

No logic beyond dispatch — the resolved transport does all the work. The `next` argument is ignored because `RouterTransport` is always terminal.

---

### 3. Pipeline configuration

Dev config replaces the static transport:

```elixir
# config/dev.exs
config :shem, llm_pipeline: [
  Shem.LLM.Middleware.BudgetCheck,
  Shem.LLM.Middleware.EventLogger,
  Shem.LLM.Middleware.RouterTransport
]

config :shem, llm_routes: %{
  default: {:llama_cpp, "qwen3.6-27b-uncensored-hauhaucs-balanced"}
}
```

Test config is unchanged — `StubTransport` remains the test pipeline. `RouterTransport` is never in the test pipeline, so no test infrastructure changes are needed.

---

### 4. `Agent.Config` and presets — no changes

`Config.model` is already an atom field. Existing presets set `model: :default`. A new preset that uses the reasoning slot would set `model: :reasoning` — the router resolves it at call time. No changes to `Config`, `Agent.Turn`, or `Agent.Server`.

---

## TUI & Interaction

### New commands in `CommandDispatch`

**`/llm route <atom>=<model> ...`**

Sets one or more routes. Example:
```
/llm route reasoning=phi4 tools=qwen3.6-27b
```

Parsing: strip `"llm route "` prefix, split remaining string on spaces, split each token on `=`. Each pair calls `Router.set_route(String.to_atom(key), :llama_cpp, value)`. Backend defaults to `:llama_cpp`; the TUI command does not expose backend selection (all local models run through llama.cpp).

Returns dispatch tuple: `{:llm_route, [{atom, backend_key, model_string}]}` — one entry per pair parsed.

Invalid format (no `=`, empty key/value): returns `{:error, "usage: /llm route <role>=<model> ..."}`.

**`/llm routes`**

Returns `{:llm_routes}`. `App.update/2` calls `Router.all()` and formats it into `command_output`:

```
routing table:
  default  → llama_cpp · qwen3.6-27b-uncensored-hauhaucs-balanced
  reasoning → llama_cpp · phi4
  tools    → llama_cpp · qwen3.6-27b-uncensored-hauhaucs-balanced
```

### `App` model

No new fields. `command_output` (added in Phase 11) already handles one-shot display strings. `/llm route` and `/llm routes` both render there, consistent with `/tools` and `/trust`.

`App.update/2` handles `{:llm_route, results}` by calling `Router.set_route/3` for each result, then setting `command_output` to a confirmation string. Handles `{:llm_routes}` by calling `Router.all()` and formatting into `command_output`.

---

## Error Handling

- `Router.resolve/1` with unknown atom → falls back to `:default`. Never errors on valid configuration.
- `Router.resolve/1` with missing `:default` → `{:error, :no_default}` → `RouterTransport` returns `{:error, {:router, :no_default}}` → surfaces in `command_error` as with other LLM errors.
- `/llm route` with malformed input → `{:error, reason}` → rendered in `command_error`.
- Transport errors pass through unchanged (same as current behaviour).

---

## Testing

### `LLM.Router`

```elixir
# test/shem/llm/router_test.exs
describe "resolve/1" do
  test "returns default route for :default atom"
  test "returns configured route after set_route/3"
  test "falls back to :default for unknown atom"
  test "returns {:error, :no_default} when :default missing"
end

describe "set_route/3" do
  test "overwrites existing route"
  test "adds new atom to route table"
end

describe "all/0" do
  test "returns full route table map"
end
```

### `RouterTransport`

```elixir
# test/shem/llm/middleware/router_transport_test.exs
describe "call/3" do
  test "resolves model atom and delegates to correct transport module"
  test "passes transport errors back unchanged"
  test "returns {:error, {:router, :no_default}} when router has no default"
end
```

Start a test `Router` via `start_supervised({Shem.LLM.Router, routes: %{default: {:llama_cpp, "test-model"}}})` with known state. Call `RouterTransport.call/3` directly.

### `CommandDispatch`

```elixir
describe "/llm route" do
  test "/llm route reasoning=phi4 → {:llm_route, [{:reasoning, :llama_cpp, \"phi4\"}]}"
  test "/llm route reasoning=phi4 tools=qwen → two-element list"
  test "/llm routes → {:llm_routes}"
  test "/llm route bad → {:error, _}"
end
```

### `App`

```elixir
describe "llm route commands" do
  test ":llm_route updates command_output with confirmation"
  test ":llm_routes renders route table into command_output"
end
```

---

## Files Changed

| File | Change |
|------|--------|
| `lib/shem/llm/router.ex` | New GenServer |
| `lib/shem/llm/middleware/router_transport.ex` | New terminal middleware |
| `lib/shem/application.ex` | Start `Router` in supervision tree |
| `config/dev.exs` | Replace static transport with `RouterTransport`; add `llm_routes` |
| `lib/shem/tui/command_dispatch.ex` | `/llm route` and `/llm routes` commands |
| `lib/shem/tui/app.ex` | Handle `{:llm_route, _}` and `{:llm_routes}` dispatch tuples |
| `test/shem/llm/router_test.exs` | New test module |
| `test/shem/llm/middleware/router_transport_test.exs` | New test module |
| `test/shem/tui/command_dispatch_test.exs` | `/llm` command tests |
| `test/shem/tui/app_test.exs` | LLM route key binding tests |
