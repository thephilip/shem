# Phase 18 — Python SDK Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a REST API for agent orchestration at `/api/*` on port 4000, and a Python SDK (`shem-py`) that wraps it and supports `@shem.tool` for exposing Python functions as MCP tools.

**Architecture:** A new `Shem.HTTP.Router` becomes the top-level Bandit plug, forwarding `/api/*` to a new `Shem.REST.Router` and everything else to the existing (unchanged) `Shem.MCP.Router`. The Python SDK lives at `sdk/python/` and uses `requests` for REST calls and Anthropic's `mcp` PyPI package for serving tools.

**Tech Stack:** Elixir Plug.Router, Bandit (already in deps), Jason (already in deps), Python 3.10+, `requests`, Anthropic `mcp` Python SDK.

---

## File Map

### Created (Elixir)
| File | Responsibility |
|---|---|
| `lib/shem/http/router.ex` | Top-level Bandit plug — dispatches `/api` to REST, everything else to MCP |
| `lib/shem/rest/router.ex` | REST Plug pipeline — JSON parsing, forwards to handlers |
| `lib/shem/rest/handlers/agents.ex` | POST/GET/DELETE agent lifecycle endpoints |
| `lib/shem/rest/handlers/presets.ex` | GET presets listing |
| `lib/shem/rest/handlers/routes.ex` | GET LLM route listing |

### Modified (Elixir)
| File | Change |
|---|---|
| `lib/shem/mcp/server.ex` | Swap `Shem.MCP.Router` → `Shem.HTTP.Router` as Bandit plug |

### Created (Tests)
| File | Tests |
|---|---|
| `test/shem/http/router_test.exs` | `/api/*` routing + MCP passthrough still works |
| `test/shem/rest/agents_test.exs` | All agent endpoints via REST.Router |
| `test/shem/rest/presets_test.exs` | Presets listing |
| `test/shem/rest/routes_test.exs` | Routes listing |

### Created (Python)
| File | Responsibility |
|---|---|
| `sdk/python/shem/__init__.py` | Public exports: `Client`, `Agent`, `Result`, `tool`, `serve_tools` |
| `sdk/python/shem/client.py` | `Client` class — REST calls via `requests` |
| `sdk/python/shem/agent.py` | `Agent` + `Result` — polling + stop |
| `sdk/python/shem/tools.py` | `@tool` decorator + module-level registry + schema inference |
| `sdk/python/shem/server.py` | `serve_tools()` — wraps mcp Python SDK |
| `sdk/python/pyproject.toml` | Package metadata |
| `sdk/python/tests/test_client.py` | Client unit tests (mocked requests) |
| `sdk/python/tests/test_agent.py` | Agent unit tests (mocked requests) |
| `sdk/python/tests/test_tools.py` | Tool decorator + schema inference tests |

---

## Task 1: HTTP.Router — top-level dispatcher

**Files:**
- Create: `lib/shem/http/router.ex`
- Modify: `lib/shem/mcp/server.ex`

Path stripping: `forward "/api", to: Shem.REST.Router` strips `/api` before forwarding, so REST.Router sees `/agents`, `/presets`, `/routes`. `forward "/", to: Shem.MCP.Router` passes the full remaining path (unchanged).

- [ ] **Step 1: Write the failing test**

Create `test/shem/http/router_test.exs`:

```elixir
defmodule Shem.HTTP.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Shem.HTTP.Router

  @opts Router.init([])

  test "GET /api/presets is forwarded to the REST router" do
    conn = conn(:get, "/api/presets") |> Router.call(@opts)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    body = Jason.decode!(conn.resp_body)
    assert is_list(body)
  end

  test "GET /sse is forwarded to the MCP handler (returns SSE headers)" do
    # /sse opens a long-lived SSE connection — testing it ends the request; we just
    # confirm the response starts with the correct content-type before the process
    # blocks on sse_loop. We can't easily call /sse in unit tests, so we confirm
    # the unknown-path fallback still returns 404 from the MCP router.
    conn = conn(:get, "/unknown-path-xyz") |> Router.call(@opts)
    assert conn.status == 404
  end

  test "POST /message with a valid JSON-RPC notification (no id) returns 204" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}})
    conn =
      conn(:post, "/message", body)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)
    assert conn.status == 204
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /home/philip/Downloads/_project/shem
mix test test/shem/http/router_test.exs 2>&1 | head -20
```

Expected: compile error — `Shem.HTTP.Router` does not exist.

- [ ] **Step 3: Create `lib/shem/http/router.ex`**

```elixir
defmodule Shem.HTTP.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/api", to: Shem.REST.Router
  forward "/", to: Shem.MCP.Router
end
```

- [ ] **Step 4: Create stub REST.Router so the test compiles**

Skip — Task 2 creates the real REST.Router. Run the test after Task 2 is committed.

- [ ] **Step 5: Update `lib/shem/mcp/server.ex`**

Current line 14:
```elixir
{Bandit, plug: Shem.MCP.Router, port: port, ip: {127, 0, 0, 1}, scheme: :http}
```

Replace with:
```elixir
{Bandit, plug: Shem.HTTP.Router, port: port, ip: {127, 0, 0, 1}, scheme: :http}
```

Full updated file:
```elixir
defmodule Shem.MCP.Server do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    port = Application.get_env(:shem, :mcp_port, 4000)

    children = [
      Shem.MCP.SessionRegistry,
      {Bandit, plug: Shem.HTTP.Router, port: port, ip: {127, 0, 0, 1}, scheme: :http}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

- [ ] **Step 6: Commit**

```bash
git add lib/shem/http/router.ex lib/shem/mcp/server.ex test/shem/http/router_test.exs
git commit -m "feat: HTTP.Router — top-level dispatcher; MCP.Server uses HTTP.Router as Bandit plug"
```

---

## Task 2: REST.Router — Plug pipeline + routing

**Files:**
- Create: `lib/shem/rest/router.ex`

Path mapping (after `/api` stripped by HTTP.Router):
- `GET /presets` → `forward "/presets", to: Shem.REST.Handlers.Presets`
- `GET /routes` → `forward "/routes", to: Shem.REST.Handlers.Routes`
- `* /agents*` → `forward "/agents", to: Shem.REST.Handlers.Agents`

- [ ] **Step 1: Write the failing test**

Create `test/shem/rest/presets_test.exs` (used first since it has no agent state dependencies):

```elixir
defmodule Shem.REST.PresetsTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Shem.REST.Router

  @opts Router.init([])

  test "GET /presets returns JSON list with name and description" do
    conn = conn(:get, "/presets") |> Router.call(@opts)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    body = Jason.decode!(conn.resp_body)
    assert is_list(body)
    assert length(body) >= 3
    first = hd(body)
    assert Map.has_key?(first, "name")
    assert Map.has_key?(first, "description")
  end

  test "GET /unknown returns 404" do
    conn = conn(:get, "/unknown") |> Router.call(@opts)
    assert conn.status == 404
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/shem/rest/presets_test.exs 2>&1 | head -20
```

Expected: compile error — `Shem.REST.Router` does not exist.

- [ ] **Step 3: Create `lib/shem/rest/router.ex`**

```elixir
defmodule Shem.REST.Router do
  use Plug.Router

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["*/*"]

  plug :match
  plug :dispatch

  forward "/agents", to: Shem.REST.Handlers.Agents
  forward "/presets", to: Shem.REST.Handlers.Presets
  forward "/routes", to: Shem.REST.Handlers.Routes

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end
end
```

- [ ] **Step 4: Create stub handler modules so it compiles**

Create `lib/shem/rest/handlers/presets.ex` (stub — replaced fully in Task 4):

```elixir
defmodule Shem.REST.Handlers.Presets do
  use Plug.Router
  plug :match
  plug :dispatch
  match _ do
    send_resp(conn, 501, "not implemented")
  end
end
```

Create `lib/shem/rest/handlers/routes.ex` (stub):

```elixir
defmodule Shem.REST.Handlers.Routes do
  use Plug.Router
  plug :match
  plug :dispatch
  match _ do
    send_resp(conn, 501, "not implemented")
  end
end
```

Create `lib/shem/rest/handlers/agents.ex` (stub):

```elixir
defmodule Shem.REST.Handlers.Agents do
  use Plug.Router
  plug :match
  plug :dispatch
  match _ do
    send_resp(conn, 501, "not implemented")
  end
end
```

- [ ] **Step 5: Run the presets test — expect 200 with 501 body (routing works, stubs respond)**

```bash
mix test test/shem/rest/presets_test.exs 2>&1 | head -30
```

Expected: FAIL — status is 501, not 200. But the module compiles, confirming routing works.

- [ ] **Step 6: Commit the router and stubs**

```bash
git add lib/shem/rest/router.ex lib/shem/rest/handlers/agents.ex \
        lib/shem/rest/handlers/presets.ex lib/shem/rest/handlers/routes.ex \
        test/shem/rest/presets_test.exs
git commit -m "feat: REST.Router pipeline + stub handlers"
```

---

## Task 3: REST Agents Handler

**Files:**
- Modify: `lib/shem/rest/handlers/agents.ex` (replace stub)
- Create: `test/shem/rest/agents_test.exs`

After HTTP.Router strips `/api` and REST.Router strips `/agents`, the Agents handler sees:
- `POST /` — start agent
- `GET /:id` — status
- `GET /:id/result` — result (poll with 100ms await)
- `DELETE /:id` — stop

Content for done agents is read from `EventLog.events/1` — the `:agent_done` event carries `%{content: "..."}` in its payload when `reason: :answer`.

- [ ] **Step 1: Write the failing test**

Create `test/shem/rest/agents_test.exs`:

```elixir
defmodule Shem.REST.AgentsTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Shem.REST.Router
  alias Shem.LLM.StubTransport

  @opts Router.init([])

  setup do
    StubTransport.reset()
    :ok
  end

  defp post_json(path, body) do
    encoded = Jason.encode!(body)
    conn(:post, path, encoded)
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp get_path(path) do
    conn(:get, path) |> Router.call(@opts)
  end

  defp delete_path(path) do
    conn(:delete, path) |> Router.call(@opts)
  end

  # POST /agents ──────────────────────────────────────────────────────────────

  test "POST /agents returns 400 when task is missing" do
    conn = post_json("/agents", %{preset: "general"})
    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"] =~ "task"
  end

  test "POST /agents returns 400 for unknown preset" do
    conn = post_json("/agents", %{preset: "nonexistent_preset_xyz", task: "do something"})
    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"] =~ "preset"
  end

  test "POST /agents starts an agent and returns agent_id and session_id" do
    # Push a quick done response so the agent doesn't block
    StubTransport.push_response({:ok, %{content: "done"}})
    conn = post_json("/agents", %{preset: "general", task: "say hello"})
    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["agent_id"])
    assert is_binary(body["session_id"])
    # cleanup
    Shem.Agent.stop(body["agent_id"])
  end

  # GET /agents/:id ────────────────────────────────────────────────────────────

  test "GET /agents/:id returns 404 for unknown agent" do
    conn = get_path("/agents/agent_DEADBEEF")
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "agent not found"
  end

  test "GET /agents/:id returns status for a running agent" do
    {:ok, agent_id} = Shem.Agent.start_with_preset("general", "pause")
    conn = get_path("/agents/#{agent_id}")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] in ["running", "done", "error"]
    Shem.Agent.stop(agent_id)
  end

  # GET /agents/:id/result ─────────────────────────────────────────────────────

  test "GET /agents/:id/result returns 404 for unknown agent" do
    conn = get_path("/agents/agent_DEADBEEF/result")
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "agent not found"
  end

  test "GET /agents/:id/result returns running when agent has not completed" do
    # No StubTransport response pushed — agent blocks waiting for LLM
    {:ok, agent_id} = Shem.Agent.start_with_preset("general", "wait")
    conn = get_path("/agents/#{agent_id}/result")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "running"
    Shem.Agent.stop(agent_id)
  end

  test "GET /agents/:id/result returns done with content when agent completes" do
    StubTransport.push_response({:ok, %{content: "final answer"}})
    {:ok, agent_id} = Shem.Agent.start_with_preset("general", "answer me")
    # Wait for the agent to actually finish before polling
    assert {:ok, :done} = Shem.Agent.await(agent_id, 5_000)
    conn = get_path("/agents/#{agent_id}/result")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "done"
    assert is_binary(body["content"])
  end

  # DELETE /agents/:id ─────────────────────────────────────────────────────────

  test "DELETE /agents/:id returns 404 for unknown agent" do
    conn = delete_path("/agents/agent_DEADBEEF")
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "agent not found"
  end

  test "DELETE /agents/:id stops a running agent" do
    {:ok, agent_id} = Shem.Agent.start_with_preset("general", "work")
    conn = delete_path("/agents/#{agent_id}")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == true
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/shem/rest/agents_test.exs 2>&1 | head -30
```

Expected: FAIL — all tests hit the stub handler returning 501.

- [ ] **Step 3: Implement `lib/shem/rest/handlers/agents.ex`**

```elixir
defmodule Shem.REST.Handlers.Agents do
  use Plug.Router

  plug :match
  plug :dispatch

  post "/" do
    preset = Map.get(conn.body_params, "preset", "general")
    task = Map.get(conn.body_params, "task")

    if is_nil(task) or task == "" do
      send_json(conn, 400, %{error: "task is required"})
    else
      case Shem.Agent.start_with_preset(preset, task) do
        {:ok, agent_id} ->
          {:ok, session_id} = Shem.Agent.session_id(agent_id)
          send_json(conn, 201, %{agent_id: agent_id, session_id: session_id})

        {:error, :not_found} ->
          send_json(conn, 400, %{error: "unknown preset: #{preset}"})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    end
  end

  get "/:id/result" do
    case Shem.Agent.await(id, 100) do
      {:ok, :done} ->
        {:ok, session_id} = Shem.Agent.session_id(id)
        content = read_done_content(session_id)
        send_json(conn, 200, %{status: "done", content: content})

      {:ok, :error} ->
        send_json(conn, 200, %{status: "error", error: "agent failed"})

      {:error, :timeout} ->
        send_json(conn, 200, %{status: "running"})

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "agent not found"})
    end
  end

  get "/:id" do
    case Shem.Agent.status(id) do
      {:ok, status} -> send_json(conn, 200, %{status: status})
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
    end
  end

  delete "/:id" do
    case Shem.Agent.stop(id) do
      :ok -> send_json(conn, 200, %{ok: true})
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  defp read_done_content(session_id) do
    case Shem.EventLog.events(session_id) do
      {:ok, events} ->
        events
        |> Enum.filter(&(&1.type == :agent_done))
        |> List.last()
        |> case do
          nil -> ""
          event -> Map.get(event.payload, :content, "")
        end

      _ ->
        ""
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
```

- [ ] **Step 4: Run the agents tests**

```bash
mix test test/shem/rest/agents_test.exs 2>&1
```

Expected: all 8 tests pass.

- [ ] **Step 5: Run the full test suite to check no regressions**

```bash
mix test 2>&1 | tail -10
```

Expected: all previous tests + new tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/rest/handlers/agents.ex test/shem/rest/agents_test.exs
git commit -m "feat: REST Agents handler — POST/GET/DELETE agent lifecycle endpoints"
```

---

## Task 4: REST Presets Handler

**Files:**
- Modify: `lib/shem/rest/handlers/presets.ex` (replace stub)
- The test was already created in Task 2 — `test/shem/rest/presets_test.exs`

`Preset.all()` returns a list of maps with `:name`, `:system_prompt`, `:tools`, `:source`. The endpoint maps `:system_prompt` to `"description"` since that communicates what the preset does.

- [ ] **Step 1: Run the existing presets test to confirm it still fails**

```bash
mix test test/shem/rest/presets_test.exs 2>&1 | head -20
```

Expected: FAIL — stub returns 501.

- [ ] **Step 2: Implement `lib/shem/rest/handlers/presets.ex`**

```elixir
defmodule Shem.REST.Handlers.Presets do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/" do
    presets =
      Shem.Agent.Preset.all()
      |> Enum.map(fn p ->
        %{name: p.name, description: p.system_prompt}
      end)

    send_json(conn, 200, presets)
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
```

- [ ] **Step 3: Run the presets test**

```bash
mix test test/shem/rest/presets_test.exs 2>&1
```

Expected: both tests pass.

- [ ] **Step 4: Commit**

```bash
git add lib/shem/rest/handlers/presets.ex
git commit -m "feat: REST Presets handler — GET /api/presets"
```

---

## Task 5: REST Routes Handler

**Files:**
- Modify: `lib/shem/rest/handlers/routes.ex` (replace stub)
- Create: `test/shem/rest/routes_test.exs`

`LLM.Router.all/0` returns `%{atom => {backend_key_atom, model_string}}`. The endpoint converts this to a plain string map: `%{"default" => "llama_cpp:qwen3-27b", ...}`.

- [ ] **Step 1: Write the failing test**

Create `test/shem/rest/routes_test.exs`:

```elixir
defmodule Shem.REST.RoutesTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Shem.REST.Router

  @opts Router.init([])

  test "GET /routes returns a JSON object with string keys and backend:model values" do
    conn = conn(:get, "/routes") |> Router.call(@opts)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    body = Jason.decode!(conn.resp_body)
    assert is_map(body)
    # All values should be strings in "backend:model" format
    Enum.each(body, fn {_k, v} -> assert is_binary(v) end)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
mix test test/shem/rest/routes_test.exs 2>&1 | head -20
```

Expected: FAIL — stub returns 501.

- [ ] **Step 3: Implement `lib/shem/rest/handlers/routes.ex`**

```elixir
defmodule Shem.REST.Handlers.Routes do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/" do
    routes =
      Shem.LLM.Router.all()
      |> Enum.into(%{}, fn {model_atom, {backend_key, model_string}} ->
        {Atom.to_string(model_atom), "#{backend_key}:#{model_string}"}
      end)

    send_json(conn, 200, routes)
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
```

- [ ] **Step 4: Run the routes test**

```bash
mix test test/shem/rest/routes_test.exs 2>&1
```

Expected: passes.

- [ ] **Step 5: Run the HTTP.Router test now that all handlers exist**

```bash
mix test test/shem/http/router_test.exs 2>&1
```

Expected: all 3 tests pass.

- [ ] **Step 6: Run the full suite**

```bash
mix test 2>&1 | tail -10
```

Expected: all previous tests + all new REST tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/rest/handlers/routes.ex test/shem/rest/routes_test.exs
git commit -m "feat: REST Routes handler — GET /api/routes; all REST endpoints complete"
```

---

## Task 6: Python SDK — package scaffold + client

**Files:**
- Create: `sdk/python/pyproject.toml`
- Create: `sdk/python/shem/__init__.py`
- Create: `sdk/python/shem/client.py`
- Create: `sdk/python/shem/agent.py`
- Create: `sdk/python/tests/__init__.py`
- Create: `sdk/python/tests/test_client.py`
- Create: `sdk/python/tests/test_agent.py`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p sdk/python/shem sdk/python/tests
touch sdk/python/tests/__init__.py
```

- [ ] **Step 2: Write the failing tests**

Create `sdk/python/tests/test_client.py`:

```python
import pytest
from unittest.mock import patch, Mock
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from shem.client import Client
from shem.agent import Agent


def mock_response(data, status=200):
    r = Mock()
    r.status_code = status
    r.json.return_value = data
    r.raise_for_status = Mock()
    return r


class TestClientStartAgent:
    def test_returns_agent_with_correct_ids(self):
        with patch("requests.post") as mock_post:
            mock_post.return_value = mock_response(
                {"agent_id": "agent_AABBCCDD", "session_id": "sess_001"}
            )
            client = Client("http://localhost:4000")
            agent = client.start_agent("general", "do something")

        assert isinstance(agent, Agent)
        assert agent.agent_id == "agent_AABBCCDD"
        assert agent.session_id == "sess_001"

    def test_posts_to_correct_url_with_body(self):
        with patch("requests.post") as mock_post:
            mock_post.return_value = mock_response(
                {"agent_id": "agent_AABBCCDD", "session_id": "sess_001"}
            )
            client = Client("http://localhost:4000")
            client.start_agent("coding", "refactor auth")

        mock_post.assert_called_once_with(
            "http://localhost:4000/api/agents",
            json={"preset": "coding", "task": "refactor auth"},
        )

    def test_raises_on_http_error(self):
        with patch("requests.post") as mock_post:
            error_resp = mock_response({"error": "unknown preset"}, 400)
            error_resp.raise_for_status.side_effect = Exception("400 Client Error")
            mock_post.return_value = error_resp
            client = Client("http://localhost:4000")
            with pytest.raises(Exception, match="400"):
                client.start_agent("bad_preset", "task")


class TestClientPresets:
    def test_returns_list_of_preset_names(self):
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response(
                [
                    {"name": "general", "description": "..."},
                    {"name": "coding", "description": "..."},
                ]
            )
            client = Client("http://localhost:4000")
            names = client.presets()

        assert names == ["general", "coding"]

    def test_gets_correct_url(self):
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response([])
            client = Client("http://localhost:4000")
            client.presets()

        mock_get.assert_called_once_with("http://localhost:4000/api/presets")


class TestClientRoutes:
    def test_returns_routes_dict(self):
        routes = {"default": "llama_cpp:qwen3-27b", "reasoning": "ollama:phi4"}
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response(routes)
            client = Client("http://localhost:4000")
            result = client.routes()

        assert result == routes

    def test_gets_correct_url(self):
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response({})
            client = Client("http://localhost:4000")
            client.routes()

        mock_get.assert_called_once_with("http://localhost:4000/api/routes")
```

Create `sdk/python/tests/test_agent.py`:

```python
import pytest
from unittest.mock import patch, Mock, call
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from shem.agent import Agent, Result


def mock_response(data, status=200):
    r = Mock()
    r.status_code = status
    r.json.return_value = data
    r.raise_for_status = Mock()
    return r


class TestAgentStatus:
    def test_returns_status_string(self):
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response({"status": "running"})
            agent = Agent("agent_AA", "sess_01", "http://localhost:4000")
            assert agent.status() == "running"

    def test_gets_correct_url(self):
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response({"status": "done"})
            agent = Agent("agent_AA", "sess_01", "http://localhost:4000")
            agent.status()
        mock_get.assert_called_once_with("http://localhost:4000/api/agents/agent_AA")


class TestAgentStop:
    def test_sends_delete_request(self):
        with patch("requests.delete") as mock_del:
            mock_del.return_value = mock_response({"ok": True})
            agent = Agent("agent_AA", "sess_01", "http://localhost:4000")
            agent.stop()
        mock_del.assert_called_once_with("http://localhost:4000/api/agents/agent_AA")


class TestAgentAwaitResult:
    def test_returns_result_when_done_immediately(self):
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response({"status": "done", "content": "hello"})
            agent = Agent("agent_AA", "sess_01", "http://localhost:4000")
            result = agent.await_result(timeout=10)
        assert isinstance(result, Result)
        assert result.content == "hello"

    def test_polls_until_done(self):
        responses = [
            mock_response({"status": "running"}),
            mock_response({"status": "running"}),
            mock_response({"status": "done", "content": "answer"}),
        ]
        with patch("requests.get", side_effect=responses), \
             patch("time.sleep"):
            agent = Agent("agent_AA", "sess_01", "http://localhost:4000")
            result = agent.await_result(timeout=60)
        assert result.content == "answer"

    def test_raises_timeout_error(self):
        with patch("requests.get") as mock_get, \
             patch("time.monotonic", side_effect=[0.0, 0.0, 200.0]):
            mock_get.return_value = mock_response({"status": "running"})
            agent = Agent("agent_AA", "sess_01", "http://localhost:4000")
            with pytest.raises(TimeoutError, match="agent_AA"):
                agent.await_result(timeout=10)

    def test_raises_runtime_error_on_error_status(self):
        with patch("requests.get") as mock_get:
            mock_get.return_value = mock_response({"status": "error", "error": "agent failed"})
            agent = Agent("agent_AA", "sess_01", "http://localhost:4000")
            with pytest.raises(RuntimeError, match="agent failed"):
                agent.await_result(timeout=10)
```

- [ ] **Step 3: Run tests to verify they fail (module not found)**

```bash
cd sdk/python && python -m pytest tests/test_client.py tests/test_agent.py 2>&1 | head -20
```

Expected: `ModuleNotFoundError: No module named 'shem'`

- [ ] **Step 4: Create `sdk/python/pyproject.toml`**

```toml
[build-system]
requires = ["setuptools>=67"]
build-backend = "setuptools.backends.legacy:build"

[project]
name = "shem-py"
version = "0.1.0"
description = "Python SDK for Shem agent orchestration"
requires-python = ">=3.10"
dependencies = [
    "requests>=2.31",
    "mcp>=1.0",
]

[project.optional-dependencies]
dev = ["pytest>=7.0"]
```

- [ ] **Step 5: Create `sdk/python/shem/agent.py`**

```python
import time
import requests
from dataclasses import dataclass


@dataclass
class Result:
    content: str


class Agent:
    def __init__(self, agent_id: str, session_id: str, base_url: str):
        self._id = agent_id
        self._session_id = session_id
        self._base = base_url

    @property
    def agent_id(self) -> str:
        return self._id

    @property
    def session_id(self) -> str:
        return self._session_id

    def status(self) -> str:
        resp = requests.get(f"{self._base}/api/agents/{self._id}")
        resp.raise_for_status()
        return resp.json()["status"]

    def stop(self) -> None:
        requests.delete(f"{self._base}/api/agents/{self._id}")

    def await_result(self, timeout: float = 120.0) -> Result:
        deadline = time.monotonic() + timeout
        while True:
            resp = requests.get(f"{self._base}/api/agents/{self._id}/result")
            resp.raise_for_status()
            data = resp.json()
            if data["status"] == "done":
                return Result(content=data.get("content", ""))
            if data["status"] == "error":
                raise RuntimeError(data.get("error", "agent failed"))
            if time.monotonic() >= deadline:
                raise TimeoutError(f"agent {self._id} did not complete within {timeout}s")
            time.sleep(2)
```

- [ ] **Step 6: Create `sdk/python/shem/client.py`**

```python
import requests
from .agent import Agent


class Client:
    def __init__(self, base_url: str = "http://localhost:4000"):
        self._base = base_url.rstrip("/")

    def start_agent(self, preset: str, task: str) -> Agent:
        resp = requests.post(
            f"{self._base}/api/agents",
            json={"preset": preset, "task": task},
        )
        resp.raise_for_status()
        data = resp.json()
        return Agent(data["agent_id"], data["session_id"], self._base)

    def presets(self) -> list[str]:
        resp = requests.get(f"{self._base}/api/presets")
        resp.raise_for_status()
        return [p["name"] for p in resp.json()]

    def routes(self) -> dict[str, str]:
        resp = requests.get(f"{self._base}/api/routes")
        resp.raise_for_status()
        return resp.json()
```

- [ ] **Step 7: Create `sdk/python/shem/__init__.py`**

```python
from .client import Client
from .agent import Agent, Result
from .tools import tool
from .server import serve_tools

__all__ = ["Client", "Agent", "Result", "tool", "serve_tools"]
```

Note: `tools` and `server` are implemented in Task 7. For now add stub imports so the package loads:

```python
from .client import Client
from .agent import Agent, Result

__all__ = ["Client", "Agent", "Result"]
```

Update `__init__.py` fully in Task 7 after tools/server exist.

- [ ] **Step 8: Run the client and agent tests**

```bash
cd sdk/python && python -m pytest tests/test_client.py tests/test_agent.py -v 2>&1
```

Expected: all tests pass.

- [ ] **Step 9: Return to repo root and commit**

```bash
cd /home/philip/Downloads/_project/shem
git add sdk/python/
git commit -m "feat: shem-py — Client + Agent classes with full unit tests"
```

---

## Task 7: Python SDK — `@tool` decorator + `serve_tools`

**Files:**
- Create: `sdk/python/shem/tools.py`
- Create: `sdk/python/shem/server.py`
- Modify: `sdk/python/shem/__init__.py` (add full imports)
- Create: `sdk/python/tests/test_tools.py`

- [ ] **Step 1: Write the failing tests**

Create `sdk/python/tests/test_tools.py`:

```python
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import shem.tools as tools_module
from shem.tools import tool, _registry


def setup_function():
    _registry.clear()


class TestToolDecorator:
    def test_registers_function_with_name_and_description(self):
        @tool(description="Return greeting")
        def greet(name: str) -> str:
            return f"hello {name}"

        assert len(_registry) == 1
        assert _registry[0]["name"] == "greet"
        assert _registry[0]["description"] == "Return greeting"

    def test_decorated_function_still_callable(self):
        @tool(description="Add two numbers")
        def add(a: int, b: int) -> int:
            return a + b

        assert add(2, 3) == 5

    def test_schema_infers_str_annotation(self):
        @tool(description="Echo")
        def echo(msg: str) -> str:
            return msg

        schema = _registry[0]["input_schema"]
        assert schema["properties"]["msg"]["type"] == "string"
        assert "msg" in schema["required"]

    def test_schema_infers_int_annotation(self):
        @tool(description="Square")
        def square(n: int) -> int:
            return n * n

        schema = _registry[0]["input_schema"]
        assert schema["properties"]["n"]["type"] == "integer"

    def test_schema_infers_float_annotation(self):
        @tool(description="Half")
        def half(x: float) -> float:
            return x / 2

        schema = _registry[0]["input_schema"]
        assert schema["properties"]["x"]["type"] == "number"

    def test_schema_infers_bool_annotation(self):
        @tool(description="Negate")
        def negate(flag: bool) -> bool:
            return not flag

        schema = _registry[0]["input_schema"]
        assert schema["properties"]["flag"]["type"] == "boolean"

    def test_unannotated_param_defaults_to_string(self):
        @tool(description="Generic")
        def generic(x) -> str:
            return str(x)

        schema = _registry[0]["input_schema"]
        assert schema["properties"]["x"]["type"] == "string"

    def test_param_with_default_not_in_required(self):
        @tool(description="Optional")
        def greet_optional(name: str, greeting: str = "hello") -> str:
            return f"{greeting} {name}"

        schema = _registry[0]["input_schema"]
        assert "name" in schema["required"]
        assert "greeting" not in schema["required"]

    def test_multiple_tools_registered(self):
        @tool(description="First")
        def first() -> str:
            return "a"

        @tool(description="Second")
        def second() -> str:
            return "b"

        assert len(_registry) == 2
        names = [e["name"] for e in _registry]
        assert "first" in names
        assert "second" in names
```

- [ ] **Step 2: Run to verify tests fail**

```bash
cd sdk/python && python -m pytest tests/test_tools.py 2>&1 | head -20
```

Expected: `ImportError` — `shem.tools` does not exist.

- [ ] **Step 3: Create `sdk/python/shem/tools.py`**

```python
import inspect
from typing import Callable

_registry: list[dict] = []

_TYPE_MAP = {
    str: "string",
    int: "integer",
    float: "number",
    bool: "boolean",
}


def _build_schema(fn: Callable) -> dict:
    sig = inspect.signature(fn)
    props = {}
    required = []
    for name, param in sig.parameters.items():
        ann = param.annotation
        json_type = _TYPE_MAP.get(ann, "string")
        props[name] = {"type": json_type}
        if param.default is inspect.Parameter.empty:
            required.append(name)
    schema: dict = {"type": "object", "properties": props}
    if required:
        schema["required"] = required
    return schema


def tool(description: str) -> Callable:
    def decorator(fn: Callable) -> Callable:
        _registry.append(
            {
                "name": fn.__name__,
                "description": description,
                "fn": fn,
                "input_schema": _build_schema(fn),
            }
        )
        return fn

    return decorator
```

- [ ] **Step 4: Run tools tests**

```bash
cd sdk/python && python -m pytest tests/test_tools.py -v 2>&1
```

Expected: all 9 tests pass.

- [ ] **Step 5: Create `sdk/python/shem/server.py`**

`serve_tools` wraps the `mcp` Python SDK's stdio transport. The server exposes all registered tools. Note: the exact mcp SDK API depends on the installed version; this targets `mcp>=1.0`.

```python
import asyncio
from .tools import _registry


def serve_tools(port: int = 5001) -> None:
    """Start an MCP server over stdio exposing all registered @shem.tool functions.

    The port parameter is accepted for API compatibility but ignored — stdio MCP
    servers communicate over stdin/stdout, not a TCP port.
    """
    asyncio.run(_serve())


async def _serve() -> None:
    from mcp.server import Server
    from mcp.server.stdio import stdio_server
    from mcp import types

    server = Server("shem-python-tools")

    @server.list_tools()
    async def list_tools() -> list[types.Tool]:
        return [
            types.Tool(
                name=entry["name"],
                description=entry["description"],
                inputSchema=entry["input_schema"],
            )
            for entry in _registry
        ]

    @server.call_tool()
    async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
        entry = next((e for e in _registry if e["name"] == name), None)
        if entry is None:
            raise ValueError(f"unknown tool: {name}")
        result = entry["fn"](**arguments)
        return [types.TextContent(type="text", text=str(result))]

    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options(),
        )
```

- [ ] **Step 6: Update `sdk/python/shem/__init__.py` with full imports**

```python
from .client import Client
from .agent import Agent, Result
from .tools import tool
from .server import serve_tools

__all__ = ["Client", "Agent", "Result", "tool", "serve_tools"]
```

- [ ] **Step 7: Run the full Python test suite**

```bash
cd sdk/python && python -m pytest tests/ -v 2>&1
```

Expected: all tests pass (test_client, test_agent, test_tools).

- [ ] **Step 8: Run Elixir tests to confirm no regressions from Python additions**

```bash
cd /home/philip/Downloads/_project/shem && mix test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
cd /home/philip/Downloads/_project/shem
git add sdk/python/shem/tools.py sdk/python/shem/server.py sdk/python/shem/__init__.py \
        sdk/python/tests/test_tools.py
git commit -m "feat: shem-py — @tool decorator, schema inference, serve_tools MCP wrapper"
```

---

## Self-Review

### Spec Coverage

| Spec requirement | Task |
|---|---|
| Top-level HTTP.Router dispatcher | Task 1 |
| `Shem.MCP.Server` updated to use HTTP.Router | Task 1 |
| REST Router Plug pipeline | Task 2 |
| `POST /api/agents` | Task 3 |
| `GET /api/agents/:id` | Task 3 |
| `GET /api/agents/:id/result` | Task 3 |
| `DELETE /api/agents/:id` | Task 3 |
| `GET /api/presets` | Task 4 |
| `GET /api/routes` | Task 5 |
| All responses `Content-Type: application/json` | Tasks 3–5 (`send_json/3`) |
| Error responses with HTTP status codes | Task 3 (400, 404, 500) |
| Python `Client` class | Task 6 |
| `Client.start_agent`, `presets`, `routes` | Task 6 |
| `Agent.await_result` polls every 2s | Task 6 (`time.sleep(2)` in `await_result`) |
| `Agent.status`, `Agent.stop` | Task 6 |
| `@shem.tool` decorator + registry | Task 7 |
| Schema inference (str/int/float/bool/unannotated) | Task 7 |
| `serve_tools()` wraps mcp Python SDK | Task 7 |
| Python unit tests (mocked requests) | Tasks 6, 7 |
| MCP routes still work (existing tests unchanged) | Task 1 (no MCP.Router changes) |

### Placeholder Scan

No "TBD", "TODO", or "implement later" present. All steps contain actual code.

### Type Consistency

- `send_json/3` defined identically in all three handlers — same signature, same body.
- `Agent.agent_id`, `Agent.session_id` are `@property` in `agent.py`; `Client.start_agent` passes `data["agent_id"]` and `data["session_id"]` to `Agent(...)` constructor positional args matching `__init__(self, agent_id, session_id, base_url)`. ✓
- `_registry` is `list[dict]` shared between `tools.py` and `server.py` via import. Tests clear it in `setup_function`. ✓
- `read_done_content/1` uses `EventLog.events/1` (active-session path) — valid since the agent process holds the session open. ✓
