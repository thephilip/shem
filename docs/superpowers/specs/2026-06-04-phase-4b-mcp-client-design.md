# Phase 4b: MCP Client — Design Spec

**Date:** 2026-06-04
**Status:** Approved

---

## 1. Scope

Phase 4b gives Shem agents the ability to call tools on external MCP servers. Shem spawns external MCP server processes (stdio transport) and routes named tool calls to them. This is the complement to Phase 4: Shem was the MCP server; now Shem is also an MCP client.

**Decisions locked in this phase:**

- Transport: **stdio via BEAM Ports** — Shem spawns and owns the OS process lifecycle.
- Config: **static** — server list defined in `config.exs`, loaded at startup.
- API: **named call** — `Shem.MCP.Client.call("server_name", "tool_name", %{args})`.

**Explicitly deferred:**

- HTTP/SSE MCP client (connecting to remote or daemon MCP servers) — Phase 6, alongside the distribution layer.
- Runtime registration of MCP servers (add/remove without restart) — Phase 5/6.
- Merging external tools into `Lab.Registry` alongside graduated tools — Phase 5.
- Per-server connection pooling (multiple OS processes per server) — Phase 5 if agents need concurrent calls.

---

## 2. Transport

MCP stdio: Shem spawns the server as an OS process via a BEAM Port. Communication is newline-delimited JSON-RPC 2.0 over stdin/stdout. Shem owns the process — if the Port exits, `ServerConn` crashes and the supervisor restarts it.

The MCP handshake (`initialize` → `initialized`) is performed by `ServerConn` on startup before any agent calls are accepted. Calls arriving before the handshake completes receive `{:error, :not_ready}`.

---

## 3. Configuration

Servers are declared in `config.exs`:

```elixir
config :shem, :mcp_clients, [
  %{name: "filesystem", cmd: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]}
]
```

Each entry requires `:name` (string, unique), `:cmd` (binary to exec), and `:args` (list of strings). `Shem.MCP.Client.Config` validates entries at startup and raises on malformed config rather than silently ignoring servers.

Test config: `config :shem, :mcp_clients, []` — no clients started by default. Per-test `ServerConn`s started explicitly where needed.

---

## 4. Component Design

```
lib/shem/mcp/client/
  config.ex          — pure; reads and validates :mcp_clients config
  protocol.ex        — pure; JSON-RPC framing/parsing for stdio (newline-delimited)
  server_conn.ex     — GenServer; owns Port, performs handshake, correlates requests
  supervisor.ex      — DynamicSupervisor; starts one ServerConn per config entry
lib/shem/mcp/
  client.ex          — public API: call/3, list_tools/1, connected_servers/0
```

### `Shem.MCP.Client` (public API)

```elixir
# Call a tool on a named server. Blocks until response or timeout.
@spec call(server :: String.t(), tool :: String.t(), args :: map(), opts :: keyword()) ::
  {:ok, any()} | {:error, any()}

# List tools advertised by a named server (from handshake capabilities).
@spec list_tools(server :: String.t()) :: {:ok, [map()]} | {:error, any()}

# List all configured servers and their connection status.
@spec connected_servers() :: [%{name: String.t(), status: :ready | :connecting | :down}]
```

### `Shem.MCP.Client.Supervisor`

`DynamicSupervisor` with `restart: :transient`. Reads config via `Client.Config` and starts one `ServerConn` per entry at application boot. Strategy: `:one_for_one`, `max_restarts: 3, max_seconds: 30` — prevents a persistently broken server from thrashing.

Registered in `Shem.Registry` under `{Shem.MCP.Client.Supervisor, :supervisor}`.

### `Shem.MCP.Client.ServerConn`

GenServer. Registered in `Shem.Registry` under `{Shem.MCP.Client.ServerConn, name}` where `name` is the string server name from config.

State:

```elixir
%{
  config: %{name: _, cmd: _, args: _},
  port: port() | nil,
  status: :connecting | :ready | :down,
  next_id: integer(),
  pending: %{request_id => {from, timer_ref}},
  tools: [map()]   # cached from initialize response
}
```

Lifecycle:
1. `init/1` — opens the Port, sends `initialize` request, sets status `:connecting`.
2. On `initialized` response — sets status `:ready`, caches tool list.
3. `handle_call({:call, tool, args}, from, state)` — assigns request ID, stores `{from, timer_ref}` in pending, writes JSON-RPC request to Port.
4. `handle_info({port, {:data, line}}, state)` — parses line via `Protocol`, matches by ID, replies to stored `from`, cancels timer.
5. `handle_info({:timeout, id}, state)` — drops pending entry, replies `{:error, :timeout}` to caller.
6. `handle_info({:EXIT, port, _reason}, state)` — replies `{:error, :server_down}` to all pending callers, crashes (supervisor restarts).

Port opened with `[:binary, :exit_status, {:line, 65536}, :use_stdio]`.

### `Shem.MCP.Client.Protocol`

Pure module. No process state.

```elixir
@spec encode_request(id :: integer(), method :: String.t(), params :: map()) :: iodata()
@spec decode_message(line :: String.t()) :: {:ok, map()} | {:error, :invalid_json | :unknown_shape}
```

### `Shem.MCP.Client.Config`

Pure module. Reads `Application.get_env(:shem, :mcp_clients, [])`, validates each entry (required keys, correct types), returns `{:ok, entries}` or raises `ArgumentError` with a clear message on bad config.

---

## 5. Request Lifecycle

```
Agent
  → Client.call("filesystem", "read_file", %{path: "/tmp/foo"})
    → ServerConn (via Shem.Registry lookup by name)
      → Port stdin: {"jsonrpc":"2.0","id":1,"method":"tools/call",...}\n
        → OS process (MCP server)
      ← Port stdout line: {"jsonrpc":"2.0","id":1,"result":{...}}\n
    ← ServerConn matches id:1, replies to caller
  ← {:ok, result}
```

---

## 6. Error Handling

| Scenario | Behaviour |
|---|---|
| Server name not in config | `{:error, :unknown_server}` immediately |
| `ServerConn` still in handshake | `{:error, :not_ready}` |
| JSON-RPC error response from server | `{:error, %{code: integer(), message: String.t()}}` |
| Call timeout (default 5000ms via `config :shem, mcp_client_timeout_ms: 5000`; overridable per call via `opts`) | `{:error, :timeout}`; pending ref dropped cleanly |
| OS process crashes mid-call | `{:error, :server_down}` to all in-flight callers; `ServerConn` crashes; supervisor restarts |
| Malformed stdout from server | Logged at `:warning`, line skipped; `ServerConn` does not crash |
| Bad config at startup | `ArgumentError` raised before supervision tree starts |

---

## 7. Testing

`Protocol` is pure — unit tests only: encode a request → assert JSON; parse a response line → assert decoded map.

`ServerConn` tests use an injected Port-opening function (same fake-store pattern as Phases 2–3). The fake returns a controlled `pid` that acts as a mock Port. Tests cover:

- Successful handshake populates tool list and sets status `:ready`
- `call/3` encodes request, stores pending entry, replies on matching response
- Multiple in-flight requests correlated correctly by ID
- Timeout drops pending ref, replies `{:error, :timeout}`, does not crash process
- `{:EXIT, port, reason}` replies `{:error, :server_down}` to all pending callers

`Client.call/3` integration tests: configure a server entry, start the supervisor with fake Port, make a call, assert the response. Full routing path exercised without a real OS process.

---

## 8. TUI

Dashboard gains one new stat line:

```
MCP clients: N connected
```

Sourced from `Client.connected_servers/0`, filtered to `status: :ready`. Surfaced via the existing 500ms subscription tick.

---

## 9. Application Wiring

`Shem.MCP.Client.Supervisor` is added to `Shem.Application` alongside `Shem.MCP.Server`, gated by the same `start_mcp: true` flag:

```elixir
defp mcp_children do
  if Application.get_env(:shem, :start_mcp, true) do
    [Shem.MCP.Server, Shem.MCP.Client.Supervisor]
  else
    []
  end
end
```

---

## 10. What This Phase Does NOT Include

- HTTP/SSE MCP client — Phase 6 (distribution layer)
- Runtime server registration (add/remove without restart) — Phase 5/6
- Merging external tools into `Lab.Registry` — Phase 5
- Per-server connection pooling — Phase 5 if needed
- Auth for outbound connections — Phase 6
