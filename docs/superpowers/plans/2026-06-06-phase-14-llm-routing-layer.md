# Phase 14 — LLM Routing Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add agent-level LLM routing so different model atoms (`:default`, `:reasoning`, `:tools`) resolve to different (backend, model_string) pairs, configurable at runtime via `/llm route` TUI commands.

**Architecture:** A `Shem.LLM.Router` GenServer holds a runtime-mutable route table. `RouterTransport` replaces the static terminal transport in the middleware pipeline, delegating to the backend resolved by the Router. Budget and event logging middleware are unchanged. Different agent presets select different model atoms; the Router resolves which transport and model string to use at call time.

**Tech Stack:** Elixir/OTP GenServer, `Shem.LLM.Middleware` behaviour (existing), Ratatouille TUI (existing), ExUnit.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/shem/llm/router.ex` | Create | Route table GenServer — resolve, set, all, flush |
| `lib/shem/llm/middleware/router_transport.ex` | Create | Terminal middleware — dispatch to resolved backend |
| `lib/shem/llm/middleware/llama_cpp_transport.ex` | Modify | Accept `model_string:` opt from RouterTransport |
| `lib/shem/llm/middleware/ollama_transport.ex` | Modify | Accept `model_string:` opt from RouterTransport |
| `lib/shem/application.ex` | Modify | Start Router in supervision tree |
| `config/dev.exs` | Modify | Replace static transport with RouterTransport; add `llm_routes` |
| `config/test.exs` | Modify | Add `llm_routes` for test Router state |
| `lib/shem/tui/command_dispatch.ex` | Modify | Parse `/llm route` and `/llm routes` |
| `lib/shem/tui/app.ex` | Modify | Handle `{:llm_route, _}` and `{:llm_routes}` tuples; `format_routes/0` |
| `test/shem/llm/router_test.exs` | Create | Router unit tests |
| `test/shem/llm/middleware/router_transport_test.exs` | Create | RouterTransport unit tests |
| `test/shem/tui/command_dispatch_test.exs` | Modify | `/llm` command tests |
| `test/shem/tui/app_test.exs` | Modify | App dispatch handler tests |

---

## Task 1: `Shem.LLM.Router` GenServer

**Files:**
- Create: `lib/shem/llm/router.ex`
- Create: `test/shem/llm/router_test.exs`

### Background

The Router is a GenServer whose state is `%{model_atom => {:llama_cpp | :ollama, model_string}}`. On `resolve/1`, it looks up the requested atom; if not found, falls back to `:default`; if `:default` is also missing, returns `{:error, :no_default}`. On init, it reads from `Application.get_env(:shem, :llm_routes, %{})`. `flush/0` re-initialises from config — used in tests to reset between test cases.

`resolve/1` returns `{transport_module, [model_string: "..."]}`  where `transport_module` is `Shem.LLM.Middleware.LlamaCppTransport` or `Shem.LLM.Middleware.OllamaTransport`. The `model_string:` key in opts tells the transport exactly which model string to use (bypassing the `llm_models` config lookup).

- [ ] **Step 1: Write the failing tests**

```elixir
# test/shem/llm/router_test.exs
defmodule Shem.LLM.RouterTest do
  use ExUnit.Case, async: false

  alias Shem.LLM.Router

  setup do
    Router.flush()
    on_exit(fn -> Router.flush() end)
    :ok
  end

  describe "resolve/1" do
    test "returns LlamaCppTransport and model_string for :default route" do
      # test.exs sets: llm_routes: %{default: {:llama_cpp, "llama3:latest"}}
      assert {Shem.LLM.Middleware.LlamaCppTransport, opts} = Router.resolve(:default)
      assert Keyword.get(opts, :model_string) == "llama3:latest"
    end

    test "returns configured route after set_route/3" do
      :ok = Router.set_route(:reasoning, :llama_cpp, "phi4")
      assert {Shem.LLM.Middleware.LlamaCppTransport, opts} = Router.resolve(:reasoning)
      assert Keyword.get(opts, :model_string) == "phi4"
    end

    test "falls back to :default for unknown atom" do
      result = Router.resolve(:__totally_unknown__)
      assert {Shem.LLM.Middleware.LlamaCppTransport, opts} = result
      assert Keyword.get(opts, :model_string) == "llama3:latest"
    end

    test "returns OllamaTransport for :ollama backend" do
      :ok = Router.set_route(:local, :ollama, "mistral")
      assert {Shem.LLM.Middleware.OllamaTransport, opts} = Router.resolve(:local)
      assert Keyword.get(opts, :model_string) == "mistral"
    end
  end

  describe "set_route/3" do
    test "overwrites existing route" do
      :ok = Router.set_route(:default, :llama_cpp, "new-model")
      assert {_, opts} = Router.resolve(:default)
      assert Keyword.get(opts, :model_string) == "new-model"
    end

    test "adds new atom to route table" do
      :ok = Router.set_route(:tools, :llama_cpp, "qwen3")
      routes = Router.all()
      assert Map.has_key?(routes, :tools)
    end
  end

  describe "all/0" do
    test "returns full route table as a map" do
      :ok = Router.set_route(:reasoning, :llama_cpp, "phi4")
      routes = Router.all()
      assert is_map(routes)
      assert Map.has_key?(routes, :default)
      assert Map.has_key?(routes, :reasoning)
    end
  end

  describe "flush/0" do
    test "resets route table to config defaults" do
      :ok = Router.set_route(:reasoning, :llama_cpp, "phi4")
      :ok = Router.flush()
      routes = Router.all()
      refute Map.has_key?(routes, :reasoning)
      assert Map.has_key?(routes, :default)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/llm/router_test.exs 2>&1 | tail -10
```

Expected: errors about `Shem.LLM.Router` not existing.

- [ ] **Step 3: Implement `Shem.LLM.Router`**

```elixir
# lib/shem/llm/router.ex
defmodule Shem.LLM.Router do
  use GenServer

  @backend_modules %{
    llama_cpp: Shem.LLM.Middleware.LlamaCppTransport,
    ollama: Shem.LLM.Middleware.OllamaTransport
  }

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec resolve(atom()) :: {module(), keyword()} | {:error, :no_default}
  def resolve(model_atom) do
    GenServer.call(__MODULE__, {:resolve, model_atom})
  end

  @spec set_route(atom(), :llama_cpp | :ollama, String.t()) :: :ok
  def set_route(model_atom, backend_key, model_string) do
    GenServer.call(__MODULE__, {:set_route, model_atom, backend_key, model_string})
  end

  @spec all() :: %{atom() => {:llama_cpp | :ollama, String.t()}}
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl true
  def init(:ok) do
    {:ok, Application.get_env(:shem, :llm_routes, %{})}
  end

  @impl true
  def handle_call({:resolve, model_atom}, _from, routes) do
    result =
      case Map.fetch(routes, model_atom) do
        {:ok, {backend_key, model_string}} ->
          build_transport(backend_key, model_string)

        :error ->
          case Map.fetch(routes, :default) do
            {:ok, {backend_key, model_string}} -> build_transport(backend_key, model_string)
            :error -> {:error, :no_default}
          end
      end

    {:reply, result, routes}
  end

  def handle_call({:set_route, model_atom, backend_key, model_string}, _from, routes) do
    {:reply, :ok, Map.put(routes, model_atom, {backend_key, model_string})}
  end

  def handle_call(:all, _from, routes) do
    {:reply, routes, routes}
  end

  def handle_call(:flush, _from, _routes) do
    {:reply, :ok, Application.get_env(:shem, :llm_routes, %{})}
  end

  defp build_transport(backend_key, model_string) do
    case Map.fetch(@backend_modules, backend_key) do
      {:ok, module} -> {module, [model_string: model_string]}
      :error -> {:error, {:unknown_backend, backend_key}}
    end
  end
end
```

- [ ] **Step 4: Verify router_test compiles**

```bash
mix compile 2>&1 | tail -5
```

Expected: no compilation errors. The Router tests will be verified to pass after Task 3 adds the Router to the Application supervision tree. Move on to the commit now.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/router.ex test/shem/llm/router_test.exs
git commit -m "feat: LLM.Router — GenServer for runtime-mutable route table"
```

---

## Task 2: `RouterTransport` + update existing transports

**Files:**
- Create: `lib/shem/llm/middleware/router_transport.ex`
- Create: `test/shem/llm/middleware/router_transport_test.exs`
- Modify: `lib/shem/llm/middleware/llama_cpp_transport.ex`
- Modify: `lib/shem/llm/middleware/ollama_transport.ex`

### Background

`RouterTransport` is the terminal middleware. It calls a `resolve_fn` (defaults to `&Shem.LLM.Router.resolve/1`) with `request.model`, gets back `{transport_module, opts}`, and delegates. The `resolve_fn` opt enables injection in tests without needing a live Router process.

Both `LlamaCppTransport` and `OllamaTransport` currently call `resolve_model(request.model)` which looks up `Application.get_env(:shem, :llm_models, %{})`. When called via RouterTransport, opts will include `model_string:` — a pre-resolved model string. Update both transports to check opts first.

- [ ] **Step 1: Write the failing tests**

Create `test/shem/llm/middleware/` directory if needed. Define stub modules at the top of the test file.

```elixir
# test/shem/llm/middleware/router_transport_test.exs
defmodule Shem.LLM.Middleware.RouterTransportTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.Middleware.RouterTransport
  alias Shem.LLM.{Request, Response}

  defmodule EchoBackend do
    @behaviour Shem.LLM.Middleware
    @impl true
    def call(request, opts, _next) do
      {:ok,
       %Response{
         content: "echo:#{Keyword.get(opts, :model_string, "none")}",
         tokens_used: 1,
         model: request.model,
         latency_ms: 0
       }}
    end
  end

  defmodule FailBackend do
    @behaviour Shem.LLM.Middleware
    @impl true
    def call(_req, _opts, _next), do: {:error, {:transport, :timeout}}
  end

  defp req(model \\ :default), do: %Request{prompt: "hello", model: model}

  describe "call/3" do
    test "delegates to resolved transport with model_string in opts" do
      resolve_fn = fn _atom -> {EchoBackend, [model_string: "phi4"]} end
      {:ok, resp} = RouterTransport.call(req(:reasoning), [resolve_fn: resolve_fn], nil)
      assert resp.content == "echo:phi4"
    end

    test "passes transport errors back unchanged" do
      resolve_fn = fn _atom -> {FailBackend, []} end
      assert {:error, {:transport, :timeout}} = RouterTransport.call(req(), [resolve_fn: resolve_fn], nil)
    end

    test "returns {:error, {:router, reason}} when resolver returns error" do
      resolve_fn = fn _atom -> {:error, :no_default} end
      assert {:error, {:router, :no_default}} = RouterTransport.call(req(), [resolve_fn: resolve_fn], nil)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/llm/middleware/router_transport_test.exs 2>&1 | tail -5
```

Expected: module not found error.

- [ ] **Step 3: Implement `RouterTransport`**

```elixir
# lib/shem/llm/middleware/router_transport.ex
defmodule Shem.LLM.Middleware.RouterTransport do
  @behaviour Shem.LLM.Middleware

  @impl true
  def call(request, opts, _next) do
    resolve_fn = Keyword.get(opts, :resolve_fn, &Shem.LLM.Router.resolve/1)

    case resolve_fn.(request.model) do
      {transport_module, transport_opts} ->
        transport_module.call(request, transport_opts, fn _ -> {:error, :no_next} end)

      {:error, reason} ->
        {:error, {:router, reason}}
    end
  end
end
```

- [ ] **Step 4: Run RouterTransport tests to verify they pass**

```bash
mix test test/shem/llm/middleware/router_transport_test.exs 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 5: Update `LlamaCppTransport` to accept `model_string:` opt**

Current `call/3` in `lib/shem/llm/middleware/llama_cpp_transport.ex`:
```elixir
body = %{
  "model" => resolve_model(request.model),
  ...
}
```

Change the `body` line and update `resolve_model/1` to `resolve_model/2`:

```elixir
# In call/3, change:
body = %{
  "model" => resolve_model(request.model, opts),
  ...
}

# Replace the existing resolve_model/1 with:
defp resolve_model(model_atom, opts) do
  case Keyword.fetch(opts, :model_string) do
    {:ok, str} ->
      str

    :error ->
      models = Application.get_env(:shem, :llm_models, %{})
      Map.get(models, model_atom, Atom.to_string(model_atom))
  end
end
```

- [ ] **Step 6: Update `OllamaTransport` to accept `model_string:` opt**

Same change in `lib/shem/llm/middleware/ollama_transport.ex`:

```elixir
# In call/3, change:
body = %{
  "model" => resolve_model(request.model, opts),
  ...
}

# Replace the existing resolve_model/1 with:
defp resolve_model(model_atom, opts) do
  case Keyword.fetch(opts, :model_string) do
    {:ok, str} ->
      str

    :error ->
      models = Application.get_env(:shem, :llm_models, %{})
      Map.get(models, model_atom, Atom.to_string(model_atom))
  end
end
```

- [ ] **Step 7: Run full test suite to verify no regressions**

```bash
mix test 2>&1 | tail -5
```

Expected: same count as before (511 passed), no failures.

- [ ] **Step 8: Commit**

```bash
git add lib/shem/llm/middleware/router_transport.ex \
        lib/shem/llm/middleware/llama_cpp_transport.ex \
        lib/shem/llm/middleware/ollama_transport.ex \
        test/shem/llm/middleware/router_transport_test.exs
git commit -m "feat: RouterTransport — terminal middleware dispatching to resolved backend"
```

---

## Task 3: Wire Router into Application and update configs

**Files:**
- Modify: `lib/shem/application.ex`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`

### Background

The Router must be started before any agent makes an LLM call. Add it to the supervision tree alongside `Trust.Store` and `PresetStore`. In `dev.exs`, replace `LlamaCppTransport` with `RouterTransport` at the terminal position and add `llm_routes`. In `test.exs`, add `llm_routes` so tests have a valid default (the test pipeline still uses `StubTransport`, so routes are only exercised in Router-specific tests).

- [ ] **Step 1: Add Router to `Application`**

In `lib/shem/application.ex`, add `Shem.LLM.Router` to the children list, after `Shem.Agent.PresetStore`:

```elixir
children =
  [
    {Horde.Registry, [name: Shem.Registry, keys: :unique, members: :auto]},
    Shem.AgentSupervisor,
    Shem.EventLog,
    Shem.Trust.Store,
    Shem.Agent.PresetStore,
    Shem.LLM.Router,          # <-- add this line
    {Task.Supervisor, name: Shem.Lab.TaskSupervisor},
    Shem.Lab.Registry,
    Shem.LLM.BudgetServer
  ] ++
    adversarial_children() ++
    llm_stub_children() ++
    mcp_children() ++
    cluster_children() ++
    tui_children()
```

- [ ] **Step 2: Update `config/dev.exs`**

Replace the static `LlamaCppTransport` entry in `llm_pipeline` with `RouterTransport`, and add `llm_routes`:

```elixir
# config/dev.exs
config :shem,
  llm_pipeline: [
    {Shem.LLM.Middleware.BudgetCheck, [budget_server: Shem.LLM.BudgetServer]},
    {Shem.LLM.Middleware.EventLogger, []},
    {Shem.LLM.Middleware.RouterTransport, []}
  ],
  llm_routes: %{
    default: {:llama_cpp, "qwen3.6-27b-uncensored-hauhaucs-balanced"}
  },
  llm_models: %{default: "qwen3.6-27b-uncensored-hauhaucs-balanced"},
  llm_llama_cpp_url: "http://localhost:1234",
  llm_budget_limit: 500_000,
  llm_soft_threshold: 0.8
```

Keep `llm_llama_cpp_url` (used by `LlamaCppTransport` for the HTTP endpoint). Keep `llm_models` as a fallback — it's harmless and the transport uses it when `model_string:` is not in opts (e.g. direct pipeline use without the Router).

- [ ] **Step 3: Update `config/test.exs`**

Add `llm_routes` so the Router has valid state in tests:

```elixir
# Add to config/test.exs alongside existing llm_pipeline config:
config :shem,
  llm_routes: %{
    default: {:llama_cpp, "llama3:latest"}
  }
```

The test pipeline stays as `StubTransport` — routes are only consulted by Router-specific tests.

- [ ] **Step 4: Run the full test suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all pass including the router_test.exs from Task 1 (Router is now started by Application).

- [ ] **Step 5: Commit**

```bash
git add lib/shem/application.ex config/dev.exs config/test.exs
git commit -m "feat: wire LLM.Router into Application supervision tree and update pipeline config"
```

---

## Task 4: `CommandDispatch` — `/llm route` and `/llm routes`

**Files:**
- Modify: `lib/shem/tui/command_dispatch.ex`
- Modify: `test/shem/tui/command_dispatch_test.exs`

### Background

Add two new command patterns under `"llm"`:

- `/llm routes` → `{:llm_routes}` (list current route table)
- `/llm route <atom>=<model> ...` → `{:llm_route, [{atom, :llama_cpp, model_string}]}` (set one or more routes)

`/llm route reasoning=phi4` → `[{:reasoning, :llama_cpp, "phi4"}]`
`/llm route reasoning=phi4 tools=qwen3` → `[{:reasoning, :llama_cpp, "phi4"}, {:tools, :llama_cpp, "qwen3"}]`

Parsing: split after `"route "`, split on spaces, split each token on `=`. Backend defaults to `:llama_cpp` for all routes set via TUI (Ollama routing is available programmatically via `Router.set_route/3` but the TUI command is llama_cpp only for simplicity). Invalid format (no `=`, empty key or value after trim) → `{:error, "usage: /llm route <role>=<model> ..."}`.

- [ ] **Step 1: Write the failing tests**

Add a new `describe` block at the bottom of `test/shem/tui/command_dispatch_test.exs`:

```elixir
describe "parse/1 — /llm commands" do
  test "/llm routes returns {:llm_routes}" do
    assert {:llm_routes} = CommandDispatch.parse("/llm routes")
  end

  test "/llm route single pair returns {:llm_route, list}" do
    assert {:llm_route, [{:reasoning, :llama_cpp, "phi4"}]} =
             CommandDispatch.parse("/llm route reasoning=phi4")
  end

  test "/llm route multiple pairs returns all routes" do
    assert {:llm_route, results} = CommandDispatch.parse("/llm route reasoning=phi4 tools=qwen3")
    assert {:reasoning, :llama_cpp, "phi4"} in results
    assert {:tools, :llama_cpp, "qwen3"} in results
  end

  test "/llm route with no pairs returns error" do
    assert {:error, msg} = CommandDispatch.parse("/llm route")
    assert msg =~ "usage: /llm route"
  end

  test "/llm route with invalid pair (no =) returns error" do
    assert {:error, msg} = CommandDispatch.parse("/llm route badformat")
    assert msg =~ "usage: /llm route"
  end

  test "/llm route with empty value returns error" do
    assert {:error, msg} = CommandDispatch.parse("/llm route reasoning=")
    assert msg =~ "usage: /llm route"
  end

  test "/llm with unknown subcommand returns error" do
    assert {:error, msg} = CommandDispatch.parse("/llm unknown")
    assert msg =~ "unknown"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/tui/command_dispatch_test.exs 2>&1 | tail -5
```

Expected: failures on the new `/llm` tests.

- [ ] **Step 3: Add `/llm` parsing to `CommandDispatch`**

In `lib/shem/tui/command_dispatch.ex`, add to the `case parts` match block (before the catch-all `_` clause):

```elixir
["llm", "routes" | _] ->
  {:llm_routes}

["llm", "route" | pair_parts] when pair_parts != [] ->
  pairs =
    pair_parts
    |> Enum.map(&String.split(&1, "=", parts: 2))
    |> Enum.filter(&match?([_, _], &1))
    |> Enum.reject(fn [k, v] -> String.trim(k) == "" or String.trim(v) == "" end)
    |> Enum.map(fn [k, v] -> {String.to_atom(String.trim(k)), :llama_cpp, String.trim(v)} end)

  if pairs == [] do
    {:error, "usage: /llm route <role>=<model> ..."}
  else
    {:llm_route, pairs}
  end

["llm", "route"] ->
  {:error, "usage: /llm route <role>=<model> ..."}

["llm" | _] ->
  {:error, "unknown /llm subcommand — try: /llm routes, /llm route <role>=<model>"}
```

Also update the `@spec` at the top of the module to add the new return types:

```elixir
@spec parse(String.t()) ::
        {:start_agent, String.t(), String.t()}
        | {:stop_agent}
        | {:list_agents}
        | {:redteam, String.t()}
        | {:tools}
        | {:trust, String.t()}
        | {:preset_list}
        | {:preset_add, String.t()}
        | {:preset_delete, String.t()}
        | {:llm_routes}
        | {:llm_route, [{atom(), :llama_cpp | :ollama, String.t()}]}
        | {:error, String.t()}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/tui/command_dispatch_test.exs 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 5: Run full suite to check for regressions**

```bash
mix test 2>&1 | tail -5
```

Expected: all pass (count increases by 7).

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/command_dispatch.ex test/shem/tui/command_dispatch_test.exs
git commit -m "feat: CommandDispatch — /llm route and /llm routes commands"
```

---

## Task 5: `App` — handle LLM route dispatch tuples

**Files:**
- Modify: `lib/shem/tui/app.ex`
- Modify: `test/shem/tui/app_test.exs`

### Background

`App.update/2` already handles many dispatch tuples from `CommandDispatch` (`:tools`, `:trust`, `:preset_list`, etc.). Add handlers for `{:llm_route, results}` and `{:llm_routes}`.

`{:llm_route, results}`: call `Router.set_route/3` for each entry, then set `command_output` to a confirmation string showing what was set.

`{:llm_routes}`: call `Router.all/0`, format the route table into a string, set as `command_output`.

Add a private `format_routes/0` helper following the same pattern as `format_tools/0` and `format_presets/0`.

The new handlers go in the `case CommandDispatch.parse(...)` block inside the Enter key handler, alongside the existing cases.

- [ ] **Step 1: Write the failing tests**

Add a new `describe` block at the bottom of `test/shem/tui/app_test.exs`:

```elixir
describe "update/2 — /llm commands" do
  setup do
    Shem.LLM.Router.flush()
    on_exit(fn -> Shem.LLM.Router.flush() end)
    :ok
  end

  test "/llm route sets route and updates command_output" do
    model = %{App.init(%{}) | mode: :interactive, command_buffer: "/llm route reasoning=phi4"}
    result = App.update(model, {:event, %{ch: 0, key: 13}})
    assert result.command_output =~ "routes updated"
    assert result.command_output =~ "reasoning"
    assert result.command_output =~ "phi4"
    assert result.command_buffer == ""
    assert result.command_error == nil
    # verify Router state was actually updated
    assert {_, opts} = Shem.LLM.Router.resolve(:reasoning)
    assert Keyword.get(opts, :model_string) == "phi4"
  end

  test "/llm routes renders route table into command_output" do
    model = %{App.init(%{}) | mode: :interactive, command_buffer: "/llm routes"}
    result = App.update(model, {:event, %{ch: 0, key: 13}})
    assert result.command_output =~ "routing table"
    assert result.command_output =~ "default"
    assert result.command_buffer == ""
    assert result.command_error == nil
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/tui/app_test.exs 2>&1 | grep -E "failed|error" | head -5
```

Expected: 2 failures on the new tests.

- [ ] **Step 3: Add handlers to `App.update/2`**

In `lib/shem/tui/app.ex`, find the `case CommandDispatch.parse(model.command_buffer)` block inside the Enter key handler. Add the new cases before the final `{:error, reason}` catch:

```elixir
{:llm_route, results} ->
  Enum.each(results, fn {atom, backend_key, model_string} ->
    Shem.LLM.Router.set_route(atom, backend_key, model_string)
  end)

  routes_str =
    Enum.map_join(results, "\n", fn {atom, _backend, model_string} ->
      "  #{atom} → #{model_string}"
    end)

  %{model | command_buffer: "", command_output: "routes updated:\n#{routes_str}", command_error: nil}

{:llm_routes} ->
  output = format_routes()
  %{model | command_buffer: "", command_output: output, command_error: nil}
```

- [ ] **Step 4: Add `format_routes/0` private helper**

Add after `format_trust/1` in `lib/shem/tui/app.ex`:

```elixir
defp format_routes do
  try do
    routes = Shem.LLM.Router.all()

    if routes == %{} do
      "No routes configured."
    else
      header = "routing table:\n"

      lines =
        routes
        |> Enum.sort_by(fn {k, _} -> to_string(k) end)
        |> Enum.map(fn {atom, {backend_key, model_string}} ->
          "  #{String.pad_trailing(to_string(atom), 12)} → #{backend_key} · #{model_string}"
        end)

      header <> Enum.join(lines, "\n")
    end
  catch
    :exit, _ -> "Router unavailable."
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/shem/tui/app_test.exs 2>&1 | tail -5
```

Expected: all pass.

- [ ] **Step 6: Run full test suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all pass (count increases by 2 from Task 5, total ~520).

- [ ] **Step 7: Commit**

```bash
git add lib/shem/tui/app.ex test/shem/tui/app_test.exs
git commit -m "feat: App — handle :llm_route and :llm_routes dispatch; format_routes/0"
```
