# Phase 4: MCP Server — Design Spec

**Date:** 2026-06-03
**Status:** Approved

---

## 1. Scope

Phase 4 exposes Shem's capabilities to external MCP clients (initially Claude Code) over HTTP/SSE. Shem acts as a persistent local daemon; Claude Code connects to it as a capability delegate — Claude reasons, Shem does BEAM-native heavy lifting.

**Explicitly deferred:**
- Shem as MCP client (Shem agents calling external MCP servers) — Phase 4b
- LLM abstraction layer / Shem-driven LLM calls — Phase 5
- Auth beyond localhost binding — Phase 6
- Multi-user or networked access — Phase 6

The four deliverables:

1. **`Shem.MCP.Server`** — supervised HTTP/SSE listener
2. **`Shem.MCP.Router`** — JSON-RPC dispatch
3. **`Shem.MCP.Handlers`** — one handler per MCP tool
4. **`Shem.Tool` input schema** — extend struct, update `run/1` calling convention

---

## 2. Transport

HTTP/SSE on `localhost:4000` (configurable via `config :shem, mcp_port: 4000`).

Shem binds to `127.0.0.1` only — no external access. Localhost binding is the sole trust boundary; no authentication is required. Auth will be revisited in Phase 6 if Shem expands beyond single-user local use.

The daemon runs continuously (`mix run --no-halt`). Killing and restarting the daemon does not lose state: graduated tools survive on disk in `~/.config/shem/lab/graduated/`, the Registry boot scan repopulates ETS on restart, and EventLog sessions persist in DETS.

SSE is used for the event stream (graduation events, tool list changes). JSON-RPC over HTTP handles all tool calls.

---

## 3. Tool Surface

Two tiers:

| Tool | Tier | Description |
|---|---|---|
| `execute_code` | Low-level | Scratch pad — compile and run Elixir source, return result. Nothing persists. Uses `Lab.Executor` directly. |
| `graduate_tool` | High-level | Atomic: compile + test + register via `GraduationGate`. Returns `%Shem.Tool{}` on success or structured failure details. |
| `list_tools` | High-level | Returns all entries from `Lab.Registry` with their input schemas. |
| `invoke_tool` | High-level | Load module on demand, call `run/1` with an args map. Return value or structured error. |

`execute_code` is the deliberate escape hatch for exploration and iteration. The graduation gate is the moat — `graduate_tool` enforces compile → test → register atomically; there is no partial graduation path.

---

## 4. Data Model Changes

`Shem.Tool` gains one new field:

```elixir
%Shem.Tool{
  # ... existing fields unchanged ...
  input_schema: map()  # JSON Schema describing run/1 argument map
                       # e.g. %{"n" => %{"type" => "integer", "description" => "..."}}
}
```

**Graduated tool calling convention:**

All graduated tools must expose:

```elixir
@spec run(map()) :: {:ok, any()} | {:error, any()}
def run(args), do: ...
```

The test harness (`GraduationGate`) continues to call `run/0` on the *test module* — the test module's `run/0` is the gate's entry point. The *implementation module's* public interface is `run/1`. These are separate concerns and do not conflict.

---

## 5. Component Design

### `Shem.MCP.Server`

GenServer wrapping an HTTP listener (Plug + Bandit). Binds to `{127, 0, 0, 1}` on the configured port. Added to `Shem.Application` supervision tree.

**New deps:** `plug ~> 1.16`, `bandit ~> 1.0` added to `mix.exs`.

```elixir
children = [
  Shem.EventLog,
  Shem.Lab.Registry,
  {Shem.MCP.Server, port: Application.get_env(:shem, :mcp_port, 4000)},
  # TUI supervisor ...
]
```

### `Shem.MCP.Router`

Plug pipeline. Routes JSON-RPC `method` field to the appropriate handler module. Returns JSON-RPC response envelopes. Handles method-not-found and malformed request errors at this layer.

### `Shem.MCP.Handlers`

One module per tool:

- `Handlers.ExecuteCode` — delegates to `Lab.Executor.run/3`
- `Handlers.GraduateTool` — delegates to `Lab.GraduationGate.run/3`
- `Handlers.ListTools` — delegates to `Lab.Registry.all/0`, formats with schemas
- `Handlers.InvokeTool` — resolves module via `Lab.Registry.lookup/1`, loads if needed, calls `Module.run(args)`

### `Shem.MCP.Schema`

Pure module. Validates incoming `args` maps against a tool's `input_schema` before dispatch. Returns `{:ok, args}` or `{:error, :invalid_args, details}`.

---

## 6. Module Loading Strategy

`invoke_tool` uses on-demand loading:

1. `Lab.Registry.lookup(id)` → `{:ok, %Shem.Tool{module: Mod, ...}}`
2. `:code.is_loaded(Mod)` — if already loaded, skip to step 4
3. `:code.load_abs(beam_path)` — load from `graduated/<id>.beam`
4. `Mod.run(args)` — call with validated args map

Modules stay in the VM for the daemon's lifetime once loaded — standard BEAM behavior, no manual unloading. On daemon restart, modules are re-loaded on first invocation (boot scan repopulates Registry metadata but does not pre-load bytecode).

---

## 7. File Layout

```
lib/shem/
  tool.ex               # add input_schema field
  mcp/
    server.ex
    router.ex
    schema.ex
    handlers/
      execute_code.ex
      graduate_tool.ex
      list_tools.ex
      invoke_tool.ex
```

---

## 8. TUI

Dashboard gains one new stat line:

```
MCP: localhost:4000 — 2 clients connected
```

Client count tracked by `Shem.MCP.Server`. Surfaced via the existing 500ms subscription tick.

---

## 9. Testing

Test config: `config :shem, mcp_port: 4001` — isolated from any live daemon on 4000.

**Protocol layer** — ExUnit HTTP client (`:httpc` or `Req`) sends raw JSON-RPC requests to the test-port server, asserts on response shape, status codes, error envelopes.

**Dispatch layer** — unit tests per handler module, injecting Registry/Executor fakes. Same fake-store pattern established in Phase 2/3.

| Module | Key test cases |
|---|---|
| `MCP.Schema` | Valid args pass through; missing required field returns error; wrong type returns error |
| `Handlers.ExecuteCode` | Valid source returns result; compile error returns structured error |
| `Handlers.GraduateTool` | Passes through to GraduationGate; formats success and failure responses |
| `Handlers.ListTools` | Returns Registry contents with schemas; empty registry returns `[]` |
| `Handlers.InvokeTool` | Module not loaded → loads and calls; module already loaded → calls directly; unknown id returns not-found |
| `MCP.Router` | Unknown method returns JSON-RPC method-not-found error; malformed JSON returns parse error |

**Integration** — manual smoke test: start Shem, configure Claude Code MCP client, call each tool, verify responses. Not automated in CI.

---

## 10. What This Phase Does NOT Include

- Shem as MCP client (calling external MCP servers) — Phase 4b
- LLM abstraction or Shem-initiated LLM calls — Phase 5
- Authentication beyond localhost binding — Phase 6
- Streaming tool responses — not required for initial tool surface
- MCP tool versioning or capability negotiation beyond the four tools above
