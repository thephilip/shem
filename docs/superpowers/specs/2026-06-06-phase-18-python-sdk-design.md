# Phase 18 — Python SDK Design

## Goal

Make Shem accessible to Python developers via two surfaces: (1) a REST API for agent orchestration and (2) a Python package (`shem-py`) that wraps the REST API and provides a `@shem.tool` decorator for registering Python functions as Shem tools via MCP.

---

## Context

Shem's MCP server (`Shem.MCP.Server`) runs on `127.0.0.1:4000` via Bandit. It currently exposes four Lab tools (`execute_code`, `graduate_tool`, `list_tools`, `invoke_tool`) over HTTP+SSE. Agent operations (start, stop, status, await result) are only accessible through the TUI. Shem's existing `Shem.MCP.Client` can connect to external MCP servers (configured via `mcp_clients` in config).

The Python MCP SDK (`mcp` on PyPI) makes it straightforward to serve MCP tools from Python. Shem's MCP client infrastructure can already connect to such a server — no changes needed to the client side for tool authorship.

---

## Architecture

### Transport

**REST for orchestration, MCP for tools.** The REST API is simpler for Python devs (plain `requests` calls). Tool authorship reuses Shem's existing MCP client infrastructure. Both surfaces share port 4000.

### Routing

A new top-level Plug dispatcher replaces `Shem.MCP.Router` as the Bandit plug:

- `/sse`, `/message` → `Shem.MCP.Handler` (existing, unchanged)
- `/api/*` → `Shem.REST.Router` (new)

---

## Design

### Section 1 — Elixir REST API

**New modules:**
- `Shem.REST.Router` — Plug pipeline, JSON request/response, routes to handlers
- `Shem.REST.Handlers.Agents` — agent lifecycle endpoints
- `Shem.REST.Handlers.Presets` — preset listing
- `Shem.REST.Handlers.Routes` — LLM route listing

**Top-level dispatcher** (`Shem.MCP.Router` becomes `Shem.HTTP.Router`):

```elixir
defmodule Shem.HTTP.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/api", to: Shem.REST.Router
  match _ , to: Shem.MCP.Handler  # handles /sse and /message
end
```

**REST endpoints:**

| Method | Path | Request body | Response |
|---|---|---|---|
| `POST` | `/api/agents` | `{"preset": "coding", "task": "refactor auth"}` | `{"agent_id": "...", "session_id": "..."}` |
| `GET` | `/api/agents/:id` | — | `{"status": "running" \| "done" \| "error"}` |
| `GET` | `/api/agents/:id/result` | — | `{"status": "running"}` or `{"status": "done", "content": "..."}` or `{"status": "error", "error": "..."}` |
| `DELETE` | `/api/agents/:id` | — | `{"ok": true}` |
| `GET` | `/api/presets` | — | `[{"name": "coding", "description": "..."}]` |
| `GET` | `/api/routes` | — | `{"default": "llama_cpp:qwen3...", "reasoning": "..."}` |

**Implementation notes:**
- `POST /api/agents` calls `Shem.Agent.start/1`, returns the agent's registered name as `agent_id`
- `GET /api/agents/:id/result` calls `Shem.Agent.await/2` with a short timeout (100ms) — returns `running` if timeout, `done` with content if complete
- The `:agent_done` event payload carries `content:` (established in Phase 7)
- `DELETE /api/agents/:id` calls `Shem.Agent.stop/1`
- All responses are `Content-Type: application/json`
- Errors: `{"error": "message"}` with appropriate HTTP status codes (400, 404, 500)
- No authentication — local use only (same `127.0.0.1` binding as MCP)

**Config:** No new config keys. REST API shares `mcp_port` (4000). `start_mcp: false` in test disables both surfaces.

---

### Section 2 — Python SDK (`shem-py`)

**Location:** `sdk/python/` within the Shem repo.

**Install:** `pip install -e sdk/python` locally. PyPI release is future work.

#### Agent Orchestration

```python
import shem

client = shem.Client("http://localhost:4000")

# Start an agent
agent = client.start_agent("coding", "refactor the auth module")

# Poll for result — blocks with a sleep loop, raises TimeoutError after timeout
result = agent.await_result(timeout=120)
print(result.content)

# Non-blocking status check
print(agent.status())   # "running" | "done" | "error"

# Stop a running agent
agent.stop()

# Discovery
print(client.presets())  # ["general", "coding", "explore", ...]
print(client.routes())   # {"default": "llama_cpp:qwen3...", ...}
```

`await_result` polls `GET /api/agents/:id/result` every 2 seconds until `status == "done"` or `status == "error"`, raising `TimeoutError` if `timeout` seconds elapse.

#### Tool Authorship

```python
import shem
import subprocess

@shem.tool(description="Run a shell command and return stdout")
def shell(command: str) -> str:
    return subprocess.check_output(command, shell=True).decode()

@shem.tool(description="Fetch a URL and return the body")
def fetch(url: str) -> str:
    import httpx
    return httpx.get(url).text

# Start a Python MCP server — Shem's MCP client connects to this
shem.serve_tools(port=5001)
```

`@shem.tool` registers the function in a module-level registry. `serve_tools()` wraps the `mcp` Python SDK to expose all registered tools as a standards-compliant MCP server.

**Connecting to Shem:** Add to `config/dev.exs`:
```elixir
config :shem, mcp_clients: [
  %{name: "python-tools", url: "http://localhost:5001"}
]
```
Or via a future `/mcp connect` TUI command. Once connected, Python tools appear in `list_tools` and agents can call them immediately via the existing `ToolDispatch` infrastructure.

**Input schema inference:** `@shem.tool` inspects the decorated function's type annotations to generate a JSON Schema for the tool's `input_schema`. `str`, `int`, `float`, `bool` map to their JSON Schema equivalents. Unannotated parameters default to `{"type": "string"}`.

#### Package Layout

```
sdk/python/
  shem/
    __init__.py      # exports: Client, Agent, Result, tool, serve_tools
    client.py        # Client class (REST calls via requests)
    agent.py         # Agent + Result classes
    tools.py         # @tool decorator + module-level registry
    server.py        # serve_tools() — wraps mcp Python SDK
  pyproject.toml     # name="shem-py", deps: requests, mcp
  README.md
```

**Dependencies:**
- `requests` — REST client (synchronous, zero-friction for Python devs)
- `mcp` — Anthropic's Python MCP SDK (`pip install mcp`)

---

## File Map

### Elixir (server-side)

| File | Action |
|---|---|
| `lib/shem/http/router.ex` | Create — top-level dispatcher (replaces MCP router as Bandit plug) |
| `lib/shem/rest/router.ex` | Create — REST Plug pipeline |
| `lib/shem/rest/handlers/agents.ex` | Create — agent lifecycle endpoints |
| `lib/shem/rest/handlers/presets.ex` | Create — preset listing |
| `lib/shem/rest/handlers/routes.ex` | Create — LLM route listing |
| `lib/shem/mcp/server.ex` | Modify — swap `Shem.MCP.Router` for `Shem.HTTP.Router` as Bandit plug |
| `test/shem/rest/` | Create — REST endpoint tests (no live agents; stub responses) |

### Python (client-side)

| File | Action |
|---|---|
| `sdk/python/shem/__init__.py` | Create |
| `sdk/python/shem/client.py` | Create |
| `sdk/python/shem/agent.py` | Create |
| `sdk/python/shem/tools.py` | Create |
| `sdk/python/shem/server.py` | Create |
| `sdk/python/pyproject.toml` | Create |

---

## Testing Strategy

**Elixir:**
- REST handler tests use `Plug.Test` — no real agents started
- `POST /api/agents` test stubs `Shem.Agent.start/1` via test config or mock
- `GET /api/agents/:id/result` tested with a stub that returns `done` immediately
- MCP routes still work after the router refactor: existing `Shem.MCP.*` tests pass unchanged

**Python:**
- Unit tests mock `requests` responses — no live Shem instance required
- `Client.start_agent` → mocked `POST /api/agents` response
- `agent.await_result` → mocked poll sequence (running × 2, then done)
- `@shem.tool` decorator → verify registry entry and generated input_schema
- `serve_tools` → not unit-tested (integration concern); documented as requiring a running MCP client

---

## Implementation Order

1. **Elixir REST API** — router refactor + endpoints + tests
2. **Python SDK** — client + tool decorator + MCP server wrapper

The Python SDK cannot be tested end-to-end until the REST API exists, but both can be developed in parallel using mocks.

---

## Future Work

- `/mcp connect <url>` TUI command to hot-add Python tool servers without config file changes
- `async` variant of the Python SDK using `httpx` and `asyncio`
- PyPI publishing (`shem-py` package)
- `shem.start_agent` shorthand at module level (skips `Client` instantiation for single-server use)
- Authentication (API key header) for remote Shem deployments
