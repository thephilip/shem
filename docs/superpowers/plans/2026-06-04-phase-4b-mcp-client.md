# Phase 4b: MCP Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an outbound MCP client so Shem can spawn external MCP servers (via stdio/BEAM Ports) and call their tools by name.

**Architecture:** A `DynamicSupervisor` starts one `ServerConn` GenServer per entry in static config. Each `ServerConn` owns a BEAM Port (the OS process), performs the MCP handshake on startup, and correlates JSON-RPC requests with waiting callers. `Shem.MCP.Client` is a thin routing module over the registry.

**Tech Stack:** Elixir/OTP GenServer, DynamicSupervisor, BEAM Ports (`Port.open/2`, `Port.command/2`), `Shem.Registry` (existing), `Jason` (existing).

---

## File Map

**New files:**
- `lib/shem/mcp/client/config.ex` — pure; reads and validates `:mcp_clients` app config
- `lib/shem/mcp/client/protocol.ex` — pure; JSON-RPC encode/decode for newline-delimited stdio
- `lib/shem/mcp/client/server_conn.ex` — GenServer; owns Port, handshake, request correlation
- `lib/shem/mcp/client/supervisor.ex` — DynamicSupervisor; starts one ServerConn per config entry
- `lib/shem/mcp/client.ex` — public API: `call/3`, `list_tools/1`, `connected_servers/0`
- `test/shem/mcp/client/config_test.exs`
- `test/shem/mcp/client/protocol_test.exs`
- `test/shem/mcp/client/server_conn_test.exs`
- `test/shem/mcp/client/supervisor_test.exs`
- `test/shem/mcp/client_test.exs`

**Modified files:**
- `lib/shem/application.ex` — add `Shem.MCP.Client.Supervisor` to `mcp_children/0`
- `lib/shem/tui/app.ex` — add `mcp_outbound_count` field to model; update `:tick` handler
- `lib/shem/tui/views/dashboard.ex` — add "MCP clients: N connected" stat line
- `config/dev.exs` — add `mcp_clients: []` and `mcp_client_timeout_ms: 5000`
- `config/test.exs` — add `mcp_clients: []` and `mcp_client_timeout_ms: 200`
- `test/shem/tui/views/dashboard_test.exs` — add `mcp_outbound_count` to base model; add stat test

---

## Task 1: `Shem.MCP.Client.Config`

**Files:**
- Create: `lib/shem/mcp/client/config.ex`
- Create: `test/shem/mcp/client/config_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/shem/mcp/client/config_test.exs
defmodule Shem.MCP.Client.ConfigTest do
  use ExUnit.Case, async: true

  alias Shem.MCP.Client.Config

  test "load/0 returns empty list when no config present" do
    Application.put_env(:shem, :mcp_clients, [])
    assert {:ok, []} = Config.load()
  end

  test "load/0 returns valid entries unchanged" do
    entry = %{name: "fs", cmd: "npx", args: ["-y", "server"]}
    Application.put_env(:shem, :mcp_clients, [entry])
    assert {:ok, [^entry]} = Config.load()
  after
    Application.put_env(:shem, :mcp_clients, [])
  end

  test "load/0 returns error for entry missing :name" do
    Application.put_env(:shem, :mcp_clients, [%{cmd: "npx", args: []}])
    assert {:error, msg} = Config.load()
    assert msg =~ "invalid"
  after
    Application.put_env(:shem, :mcp_clients, [])
  end

  test "load/0 returns error for entry missing :cmd" do
    Application.put_env(:shem, :mcp_clients, [%{name: "fs", args: []}])
    assert {:error, msg} = Config.load()
    assert msg =~ "invalid"
  after
    Application.put_env(:shem, :mcp_clients, [])
  end

  test "load/0 returns error for entry missing :args" do
    Application.put_env(:shem, :mcp_clients, [%{name: "fs", cmd: "npx"}])
    assert {:error, msg} = Config.load()
    assert msg =~ "invalid"
  after
    Application.put_env(:shem, :mcp_clients, [])
  end

  test "load/0 returns error when :name is not a binary" do
    Application.put_env(:shem, :mcp_clients, [%{name: :fs, cmd: "npx", args: []}])
    assert {:error, _} = Config.load()
  after
    Application.put_env(:shem, :mcp_clients, [])
  end

  test "load/0 returns error when :args is not a list" do
    Application.put_env(:shem, :mcp_clients, [%{name: "fs", cmd: "npx", args: "bad"}])
    assert {:error, _} = Config.load()
  after
    Application.put_env(:shem, :mcp_clients, [])
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/philip/Downloads/_project/shem
mix test test/shem/mcp/client/config_test.exs 2>&1 | head -20
```

Expected: compilation error — `Shem.MCP.Client.Config` does not exist.

- [ ] **Step 3: Implement `Config`**

```elixir
# lib/shem/mcp/client/config.ex
defmodule Shem.MCP.Client.Config do
  @spec load() :: {:ok, [map()]} | {:error, String.t()}
  def load do
    Application.get_env(:shem, :mcp_clients, [])
    |> validate_all()
  end

  defp validate_all(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case validate(entry) do
        :ok -> {:cont, {:ok, acc ++ [entry]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate(%{name: n, cmd: c, args: a})
       when is_binary(n) and is_binary(c) and is_list(a),
       do: :ok

  defp validate(entry),
    do: {:error, "invalid mcp_clients entry: #{inspect(entry)}"}
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/mcp/client/config_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/client/config.ex test/shem/mcp/client/config_test.exs
git commit -m "feat: Shem.MCP.Client.Config — validate :mcp_clients app config"
```

---

## Task 2: `Shem.MCP.Client.Protocol`

**Files:**
- Create: `lib/shem/mcp/client/protocol.ex`
- Create: `test/shem/mcp/client/protocol_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/shem/mcp/client/protocol_test.exs
defmodule Shem.MCP.Client.ProtocolTest do
  use ExUnit.Case, async: true

  alias Shem.MCP.Client.Protocol

  describe "encode_request/3" do
    test "produces a valid JSON-RPC 2.0 request line" do
      line = Protocol.encode_request(1, "tools/call", %{"name" => "read_file"})
      assert String.ends_with?(line, "\n")
      decoded = Jason.decode!(String.trim_trailing(line))
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["method"] == "tools/call"
      assert decoded["params"] == %{"name" => "read_file"}
    end

    test "encodes id 0 for handshake initialize" do
      line = Protocol.encode_request(0, "initialize", %{})
      decoded = Jason.decode!(String.trim_trailing(line))
      assert decoded["id"] == 0
    end
  end

  describe "encode_notification/2" do
    test "produces a JSON-RPC 2.0 notification (no id field)" do
      line = Protocol.encode_notification("notifications/initialized", %{})
      assert String.ends_with?(line, "\n")
      decoded = Jason.decode!(String.trim_trailing(line))
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "notifications/initialized"
      refute Map.has_key?(decoded, "id")
    end
  end

  describe "decode_message/1" do
    test "decodes a valid JSON-RPC 2.0 response" do
      line = ~s({"jsonrpc":"2.0","id":1,"result":{"ok":true}})
      assert {:ok, %{"id" => 1, "result" => %{"ok" => true}}} = Protocol.decode_message(line)
    end

    test "returns error for invalid JSON" do
      assert {:error, :invalid_json} = Protocol.decode_message("not json")
    end

    test "returns error for JSON missing jsonrpc field" do
      assert {:error, :unknown_shape} = Protocol.decode_message(~s({"id":1}))
    end

    test "returns error for jsonrpc version other than 2.0" do
      assert {:error, :unknown_shape} =
               Protocol.decode_message(~s({"jsonrpc":"1.0","id":1,"result":{}}))
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/mcp/client/protocol_test.exs 2>&1 | head -20
```

Expected: compilation error — `Shem.MCP.Client.Protocol` does not exist.

- [ ] **Step 3: Implement `Protocol`**

```elixir
# lib/shem/mcp/client/protocol.ex
defmodule Shem.MCP.Client.Protocol do
  @spec encode_request(id :: non_neg_integer(), method :: String.t(), params :: map()) :: String.t()
  def encode_request(id, method, params) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}) <>
      "\n"
  end

  @spec encode_notification(method :: String.t(), params :: map()) :: String.t()
  def encode_notification(method, params) do
    Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params}) <> "\n"
  end

  @spec decode_message(line :: String.t()) ::
          {:ok, map()} | {:error, :invalid_json | :unknown_shape}
  def decode_message(line) do
    case Jason.decode(line) do
      {:ok, %{"jsonrpc" => "2.0"} = msg} -> {:ok, msg}
      {:ok, _} -> {:error, :unknown_shape}
      {:error, _} -> {:error, :invalid_json}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/mcp/client/protocol_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/client/protocol.ex test/shem/mcp/client/protocol_test.exs
git commit -m "feat: Shem.MCP.Client.Protocol — JSON-RPC framing for stdio transport"
```

---

## Task 3: `ServerConn` — init and handshake

**Files:**
- Create: `lib/shem/mcp/client/server_conn.ex`
- Create: `test/shem/mcp/client/server_conn_test.exs`

### Background: test helpers

`ServerConn` accepts two injectable functions in opts:
- `port_opener: fn(cmd, args) -> term()` — returns a "port" identifier (real Port in prod, a pid in tests)
- `port_writer: fn(port, data) -> :ok` — writes data to the port

In tests, `port_writer` sends `{:port_write, self(), data}` to the fake port pid, where `self()` is the ServerConn process (the caller of port_writer). The fake port pid receives `{:port_write, conn_pid, data}` and can respond by sending `{fake_pid, {:data, {:eol, json_line}}}` to `conn_pid`.

The real Port (with `{:line, 65536}` option) delivers: `{port, {:data, {:eol, line}}}`.

### MCP handshake sequence

1. ServerConn opens port, sends `initialize` request (id: 0)
2. On `{:eol, line}` where line is the `initialize` response (id: 0):
   - Sends `notifications/initialized` notification (no id)
   - Sends `tools/list` request (id: 1)
3. On `{:eol, line}` where line is the `tools/list` response (id: 1):
   - Caches `tools` list from result
   - Sets status `:ready`

- [ ] **Step 1: Write the failing tests for init and handshake**

```elixir
# test/shem/mcp/client/server_conn_test.exs
defmodule Shem.MCP.Client.ServerConnTest do
  use ExUnit.Case, async: true

  alias Shem.MCP.Client.ServerConn

  # ---- test helpers ----

  # Starts a ServerConn with a fake port (test process acts as intermediary).
  # port_writer sends {:port_write, conn_pid, data} to the fake port pid.
  # Call drive_handshake/2 after start_supervised to complete the handshake.
  defp start_conn(name, extra_opts \\ []) do
    fake_pid = self()

    port_opener = fn _cmd, _args ->
      fake_pid
    end

    port_writer = fn port, data ->
      send(port, {:port_write, self(), data})
    end

    opts =
      [
        config: %{name: name, cmd: "fake", args: []},
        port_opener: port_opener,
        port_writer: port_writer,
        registry: Shem.Registry
      ] ++ extra_opts

    start_supervised!({ServerConn, opts})
  end

  # Drives the MCP handshake from the test side.
  # Receives 3 port_write messages (initialize, notifications/initialized, tools/list)
  # and sends back the appropriate responses.
  defp drive_handshake(conn_pid, tools \\ []) do
    fake_pid = self()

    # Receive initialize request, send initialize response
    assert_receive {:port_write, ^conn_pid, _init_req}, 500
    init_resp =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 0,
        "result" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "test-server", "version" => "0.1"}
        }
      })

    send(conn_pid, {fake_pid, {:data, {:eol, init_resp}}})

    # Receive notifications/initialized (no response needed)
    assert_receive {:port_write, ^conn_pid, _notif}, 500

    # Receive tools/list request, send tools/list response
    assert_receive {:port_write, ^conn_pid, _tools_req}, 500
    tools_resp =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{"tools" => tools}
      })

    send(conn_pid, {fake_pid, {:data, {:eol, tools_resp}}})

    # Give ServerConn time to process
    Process.sleep(20)
  end

  # ---- tests ----

  test "starts with status :connecting" do
    conn = start_conn("t1")
    # Drain handshake messages so the process stays alive
    state = :sys.get_state(conn)
    assert state.status == :connecting
  end

  test "transitions to :ready after successful handshake" do
    conn = start_conn("t2")
    drive_handshake(conn)
    state = :sys.get_state(conn)
    assert state.status == :ready
  end

  test "caches tool list from tools/list response" do
    conn = start_conn("t3")
    tool = %{"name" => "read_file", "description" => "reads a file", "inputSchema" => %{}}
    drive_handshake(conn, [tool])
    assert {:ok, [^tool]} = GenServer.call(conn, :list_tools)
  end

  test "list_tools returns empty list when server has no tools" do
    conn = start_conn("t4")
    drive_handshake(conn)
    assert {:ok, []} = GenServer.call(conn, :list_tools)
  end

  test "status call returns :ready after handshake" do
    conn = start_conn("t5")
    drive_handshake(conn)
    assert :ready = GenServer.call(conn, :status)
  end

  test "registers in Shem.Registry under {ServerConn, name}" do
    conn = start_conn("t6")
    drive_handshake(conn)
    assert [{^conn, _}] =
             Registry.lookup(Shem.Registry, {ServerConn, "t6"})
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/mcp/client/server_conn_test.exs 2>&1 | head -20
```

Expected: compilation error — `Shem.MCP.Client.ServerConn` does not exist.

- [ ] **Step 3: Implement `ServerConn` init and handshake**

```elixir
# lib/shem/mcp/client/server_conn.ex
defmodule Shem.MCP.Client.ServerConn do
  use GenServer

  alias Shem.MCP.Client.Protocol

  @handshake_init_id 0
  @handshake_tools_id 1

  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    registry = Keyword.get(opts, :registry, Shem.Registry)
    via = {:via, Registry, {registry, {__MODULE__, config.name}}}
    GenServer.start_link(__MODULE__, opts, name: via)
  end

  def child_spec(opts) do
    config = Keyword.fetch!(opts, :config)
    %{
      id: {__MODULE__, config.name},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)

    port_opener =
      Keyword.get(opts, :port_opener, &default_port_opener/2)

    port_writer =
      Keyword.get(opts, :port_writer, &default_port_writer/2)

    port = port_opener.(config.cmd, config.args)

    state = %{
      config: config,
      port: port,
      port_writer: port_writer,
      status: :connecting,
      handshake_step: :awaiting_init,
      next_id: 2,
      pending: %{},
      tools: []
    }

    send_to_port(state, Protocol.encode_request(@handshake_init_id, "initialize", %{
      "protocolVersion" => "2024-11-05",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "shem", "version" => "0.1.0"}
    }))

    {:ok, state}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    {:reply, {:ok, state.tools}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Protocol.decode_message(line) do
      {:ok, msg} -> handle_message(msg, state)
      {:error, reason} ->
        require Logger
        Logger.warning("ServerConn #{state.config.name}: malformed line (#{reason}), skipping")
        {:noreply, state}
    end
  end

  def handle_info({port, {:data, {:noeol, _}}}, %{port: port} = state) do
    require Logger
    Logger.warning("ServerConn #{state.config.name}: oversized line from server, skipping")
    {:noreply, state}
  end

  # --- private ---

  defp handle_message(%{"id" => @handshake_init_id, "result" => _}, %{handshake_step: :awaiting_init} = state) do
    send_to_port(state, Protocol.encode_notification("notifications/initialized", %{}))
    send_to_port(state, Protocol.encode_request(@handshake_tools_id, "tools/list", %{}))
    {:noreply, %{state | handshake_step: :awaiting_tools}}
  end

  defp handle_message(%{"id" => @handshake_tools_id, "result" => %{"tools" => tools}}, %{handshake_step: :awaiting_tools} = state) do
    {:noreply, %{state | status: :ready, handshake_step: nil, tools: tools}}
  end

  defp handle_message(_msg, state) do
    {:noreply, state}
  end

  defp send_to_port(state, data), do: state.port_writer.(state.port, data)

  defp default_port_opener(cmd, args) do
    executable = System.find_executable(cmd) || raise "mcp client command not found: #{cmd}"
    Port.open({:spawn_executable, executable}, [
      :binary,
      :exit_status,
      {:line, 65_536},
      :use_stdio,
      {:args, args}
    ])
  end

  defp default_port_writer(port, data), do: Port.command(port, data)
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/mcp/client/server_conn_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/client/server_conn.ex test/shem/mcp/client/server_conn_test.exs
git commit -m "feat: ServerConn init and MCP handshake (initialize → tools/list)"
```

---

## Task 4: `ServerConn` — call/response correlation

**Files:**
- Modify: `lib/shem/mcp/client/server_conn.ex`
- Modify: `test/shem/mcp/client/server_conn_test.exs`

- [ ] **Step 1: Write failing tests — append to `server_conn_test.exs`**

Add these tests inside `Shem.MCP.Client.ServerConnTest`, after the existing tests. They reuse the `start_conn/1` and `drive_handshake/2` helpers already defined.

```elixir
  describe "call/response correlation" do
    test "call returns {:ok, result} when server responds correctly" do
      conn = start_conn("c1")
      drive_handshake(conn)
      fake_pid = self()

      task = Task.async(fn ->
        GenServer.call(conn, {:call, "read_file", %{"path" => "/tmp/x"}})
      end)

      # Receive the tools/call request
      assert_receive {:port_write, ^conn, req_data}, 500
      decoded = Jason.decode!(req_data)
      id = decoded["id"]
      assert decoded["method"] == "tools/call"
      assert decoded["params"]["name"] == "read_file"

      # Send back a response
      resp = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"content" => "hello"}})
      send(conn, {fake_pid, {:data, {:eol, resp}}})

      assert {:ok, %{"content" => "hello"}} = Task.await(task)
    end

    test "multiple in-flight calls are correlated independently" do
      conn = start_conn("c2")
      drive_handshake(conn)
      fake_pid = self()

      task1 = Task.async(fn -> GenServer.call(conn, {:call, "tool_a", %{}}) end)
      task2 = Task.async(fn -> GenServer.call(conn, {:call, "tool_b", %{}}) end)

      # Receive both requests, capture ids
      assert_receive {:port_write, ^conn, req1}, 500
      assert_receive {:port_write, ^conn, req2}, 500
      id1 = Jason.decode!(req1)["id"]
      id2 = Jason.decode!(req2)["id"]
      assert id1 != id2

      # Respond in reverse order
      send(conn, {fake_pid, {:data, {:eol, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id2, "result" => %{"from" => "b"}})}}})
      send(conn, {fake_pid, {:data, {:eol, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id1, "result" => %{"from" => "a"}})}}})

      assert {:ok, %{"from" => "a"}} = Task.await(task1)
      assert {:ok, %{"from" => "b"}} = Task.await(task2)
    end

    test "call returns {:error, ...} when server returns a JSON-RPC error" do
      conn = start_conn("c3")
      drive_handshake(conn)
      fake_pid = self()

      task = Task.async(fn -> GenServer.call(conn, {:call, "bad_tool", %{}}) end)

      assert_receive {:port_write, ^conn, req_data}, 500
      id = Jason.decode!(req_data)["id"]

      err_resp = Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32601, "message" => "method not found"}
      })
      send(conn, {fake_pid, {:data, {:eol, err_resp}}})

      assert {:error, %{"code" => -32601, "message" => "method not found"}} = Task.await(task)
    end

    test "call returns {:error, :not_ready} when status is :connecting" do
      conn = start_conn("c4")
      # Do NOT drive handshake — status stays :connecting
      # Drain the initialize port_write so the process doesn't block
      assert_receive {:port_write, ^conn, _}, 500
      assert {:error, :not_ready} = GenServer.call(conn, {:call, "tool", %{}})
    end
  end
```

- [ ] **Step 2: Run tests to verify new tests fail**

```bash
mix test test/shem/mcp/client/server_conn_test.exs 2>&1 | tail -20
```

Expected: failures on the 4 new `call/response correlation` tests.

- [ ] **Step 3: Add `handle_call` for `{:call, tool, args}` and update `handle_message` for normal responses**

In `lib/shem/mcp/client/server_conn.ex`, add these `handle_call` and update `handle_message`:

```elixir
  # Add after existing handle_call clauses:

  def handle_call({:call, _tool, _args}, _from, %{status: :connecting} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:call, tool, args}, from, state) do
    timeout_ms = Application.get_env(:shem, :mcp_client_timeout_ms, 5_000)
    id = state.next_id
    timer_ref = Process.send_after(self(), {:timeout, id}, timeout_ms)
    send_to_port(state, Protocol.encode_request(id, "tools/call", %{"name" => tool, "arguments" => args}))
    pending = Map.put(state.pending, id, {from, timer_ref})
    {:noreply, %{state | next_id: id + 1, pending: pending}}
  end
```

Update `handle_message/2` — add two clauses before the catch-all:

```elixir
  defp handle_message(%{"id" => id, "result" => result}, state) when is_map_key(state.pending, id) do
    {{from, timer_ref}, pending} = Map.pop(state.pending, id)
    Process.cancel_timer(timer_ref)
    GenServer.reply(from, {:ok, result})
    {:noreply, %{state | pending: pending}}
  end

  defp handle_message(%{"id" => id, "error" => error}, state) when is_map_key(state.pending, id) do
    {{from, timer_ref}, pending} = Map.pop(state.pending, id)
    Process.cancel_timer(timer_ref)
    GenServer.reply(from, {:error, error})
    {:noreply, %{state | pending: pending}}
  end
```

Also add `handle_info` for the timeout message:

```elixir
  def handle_info({:timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer_ref}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end
```

- [ ] **Step 4: Run all ServerConn tests**

```bash
mix test test/shem/mcp/client/server_conn_test.exs
```

Expected: 10 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/client/server_conn.ex test/shem/mcp/client/server_conn_test.exs
git commit -m "feat: ServerConn call/response correlation with timeout support"
```

---

## Task 5: `ServerConn` — error paths

**Files:**
- Modify: `lib/shem/mcp/client/server_conn.ex`
- Modify: `test/shem/mcp/client/server_conn_test.exs`

- [ ] **Step 1: Write failing tests — append to `server_conn_test.exs`**

```elixir
  describe "error paths" do
    test "malformed stdout line is skipped, ServerConn does not crash" do
      conn = start_conn("e1")
      drive_handshake(conn)
      fake_pid = self()

      send(conn, {fake_pid, {:data, {:eol, "not json at all"}}})
      Process.sleep(20)

      # ServerConn is still alive
      assert Process.alive?(conn)
      assert :ready = GenServer.call(conn, :status)
    end

    test "oversized line (noeol) is skipped, ServerConn does not crash" do
      conn = start_conn("e2")
      drive_handshake(conn)
      fake_pid = self()

      send(conn, {fake_pid, {:data, {:noeol, "x"}}})
      Process.sleep(20)

      assert Process.alive?(conn)
    end

    test "port exit_status sends :server_down to in-flight callers" do
      conn = start_conn("e3")
      drive_handshake(conn)
      fake_pid = self()

      task = Task.async(fn ->
        GenServer.call(conn, {:call, "slow_tool", %{}}, 2_000)
      end)

      # Wait for the port_write
      assert_receive {:port_write, ^conn, _}, 500

      # Simulate OS process exit
      Process.flag(:trap_exit, true)
      send(conn, {fake_pid, {:exit_status, 1}})

      assert {:error, :server_down} = Task.await(task, 1_000)
    end
  end
```

- [ ] **Step 2: Run tests to verify new tests fail**

```bash
mix test test/shem/mcp/client/server_conn_test.exs 2>&1 | tail -20
```

Expected: failures on the 3 new `error paths` tests.

- [ ] **Step 3: Add `handle_info` for port exit and update malformed-line handling**

The malformed-line warning is already handled in Task 3. Add the `{:exit_status, _}` handler in `lib/shem/mcp/client/server_conn.ex`:

```elixir
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    require Logger
    Logger.warning("ServerConn #{state.config.name}: OS process exited with status #{code}")

    Enum.each(state.pending, fn {_id, {from, timer_ref}} ->
      Process.cancel_timer(timer_ref)
      GenServer.reply(from, {:error, :server_down})
    end)

    {:stop, {:port_exited, code}, %{state | status: :down, pending: %{}}}
  end
```

- [ ] **Step 4: Run all ServerConn tests**

```bash
mix test test/shem/mcp/client/server_conn_test.exs
```

Expected: 13 tests, 0 failures.

- [ ] **Step 5: Run full test suite to check for regressions**

```bash
mix test
```

Expected: all tests passing.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/mcp/client/server_conn.ex test/shem/mcp/client/server_conn_test.exs
git commit -m "feat: ServerConn error paths — port crash, malformed lines, oversized lines"
```

---

## Task 6: `Shem.MCP.Client.Supervisor`

**Files:**
- Create: `lib/shem/mcp/client/supervisor.ex`
- Create: `test/shem/mcp/client/supervisor_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/shem/mcp/client/supervisor_test.exs
defmodule Shem.MCP.Client.SupervisorTest do
  use ExUnit.Case, async: true

  alias Shem.MCP.Client.Supervisor, as: ClientSup

  test "starts with no children when mcp_clients config is empty" do
    Application.put_env(:shem, :mcp_clients, [])

    {:ok, sup} = start_supervised({ClientSup, name: :test_client_sup_1})
    assert [] = DynamicSupervisor.which_children(sup)
  after
    Application.put_env(:shem, :mcp_clients, [])
  end

  test "raises ArgumentError on invalid config entry" do
    Application.put_env(:shem, :mcp_clients, [%{bad: :entry}])

    assert_raise ArgumentError, ~r/mcp_clients config error/, fn ->
      start_supervised!({ClientSup, name: :test_client_sup_bad})
    end
  after
    Application.put_env(:shem, :mcp_clients, [])
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/mcp/client/supervisor_test.exs 2>&1 | head -20
```

Expected: compilation error — `Shem.MCP.Client.Supervisor` does not exist.

- [ ] **Step 3: Implement `Supervisor`**

```elixir
# lib/shem/mcp/client/supervisor.ex
defmodule Shem.MCP.Client.Supervisor do
  use DynamicSupervisor

  alias Shem.MCP.Client.Config

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case DynamicSupervisor.start_link(__MODULE__, opts, name: name) do
      {:ok, pid} ->
        case Config.load() do
          {:ok, entries} ->
            Enum.each(entries, fn entry ->
              DynamicSupervisor.start_child(pid, {Shem.MCP.Client.ServerConn, config: entry})
            end)

            {:ok, pid}

          {:error, reason} ->
            DynamicSupervisor.stop(pid)
            raise ArgumentError, "mcp_clients config error: #{reason}"
        end

      other ->
        other
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 3, max_seconds: 30)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/mcp/client/supervisor_test.exs
```

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: all tests passing.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/mcp/client/supervisor.ex test/shem/mcp/client/supervisor_test.exs
git commit -m "feat: Shem.MCP.Client.Supervisor — DynamicSupervisor bootstrapped from static config"
```

---

## Task 7: `Shem.MCP.Client` public API

**Files:**
- Create: `lib/shem/mcp/client.ex`
- Create: `test/shem/mcp/client_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/shem/mcp/client_test.exs
defmodule Shem.MCP.ClientTest do
  use ExUnit.Case, async: true

  alias Shem.MCP.Client
  alias Shem.MCP.Client.ServerConn

  # Start a ServerConn with a fake port, drive handshake, and register under the test registry.
  defp start_ready_conn(name) do
    test_pid = self()

    port_opener = fn _cmd, _args -> test_pid end
    port_writer = fn port, data -> send(port, {:port_write, self(), data}) end

    conn =
      start_supervised!(
        {ServerConn,
         config: %{name: name, cmd: "fake", args: []},
         port_opener: port_opener,
         port_writer: port_writer,
         registry: Shem.Registry}
      )

    # Drive handshake
    tool = %{"name" => "read_file", "description" => "reads a file", "inputSchema" => %{}}
    assert_receive {:port_write, ^conn, _init}, 500
    send(conn, {test_pid, {:data, {:eol, Jason.encode!(%{"jsonrpc" => "2.0", "id" => 0, "result" => %{"protocolVersion" => "2024-11-05", "capabilities" => %{}, "serverInfo" => %{"name" => "t", "version" => "0.1"}}})}}})
    assert_receive {:port_write, ^conn, _notif}, 500
    assert_receive {:port_write, ^conn, _tools_req}, 500
    send(conn, {test_pid, {:data, {:eol, Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => [tool]}})}}})
    Process.sleep(20)

    {conn, tool}
  end

  test "call/3 routes to the correct ServerConn and returns result" do
    {conn, _tool} = start_ready_conn("test-fs")
    test_pid = self()

    task = Task.async(fn -> Client.call("test-fs", "read_file", %{"path" => "/tmp/x"}) end)

    assert_receive {:port_write, ^conn, req_data}, 500
    id = Jason.decode!(req_data)["id"]
    resp = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"text" => "hello"}})
    send(conn, {test_pid, {:data, {:eol, resp}}})

    assert {:ok, %{"text" => "hello"}} = Task.await(task)
  end

  test "call/3 returns {:error, :unknown_server} for unregistered name" do
    assert {:error, :unknown_server} = Client.call("no-such-server", "tool", %{})
  end

  test "list_tools/1 returns tools for a ready server" do
    {_conn, tool} = start_ready_conn("test-fs2")
    assert {:ok, [^tool]} = Client.list_tools("test-fs2")
  end

  test "list_tools/1 returns {:error, :unknown_server} for unknown name" do
    assert {:error, :unknown_server} = Client.list_tools("ghost")
  end

  test "connected_servers/0 includes the ready server with status :ready" do
    {_conn, _} = start_ready_conn("test-fs3")
    servers = Client.connected_servers()
    assert Enum.any?(servers, &(&1.name == "test-fs3" and &1.status == :ready))
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/shem/mcp/client_test.exs 2>&1 | head -20
```

Expected: compilation error — `Shem.MCP.Client` does not exist.

- [ ] **Step 3: Implement `Shem.MCP.Client`**

```elixir
# lib/shem/mcp/client.ex
defmodule Shem.MCP.Client do
  alias Shem.MCP.Client.ServerConn

  @spec call(server :: String.t(), tool :: String.t(), args :: map(), opts :: keyword()) ::
          {:ok, any()} | {:error, any()}
  def call(server_name, tool_name, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Application.get_env(:shem, :mcp_client_timeout_ms, 5_000))

    case lookup_conn(server_name) do
      {:ok, pid} ->
        # Add buffer so ServerConn's internal timeout fires before GenServer call times out
        GenServer.call(pid, {:call, tool_name, args}, timeout + 500)

      {:error, :not_found} ->
        {:error, :unknown_server}
    end
  end

  @spec list_tools(server :: String.t()) :: {:ok, [map()]} | {:error, any()}
  def list_tools(server_name) do
    case lookup_conn(server_name) do
      {:ok, pid} -> GenServer.call(pid, :list_tools)
      {:error, :not_found} -> {:error, :unknown_server}
    end
  end

  @spec connected_servers() :: [%{name: String.t(), status: :ready | :connecting | :down}]
  def connected_servers do
    Registry.select(Shem.Registry, [
      {{{ServerConn, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.map(fn {name, pid} ->
      status =
        try do
          GenServer.call(pid, :status, 500)
        catch
          :exit, _ -> :down
        end

      %{name: name, status: status}
    end)
  end

  defp lookup_conn(name) do
    case Registry.lookup(Shem.Registry, {ServerConn, name}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end
```

- [ ] **Step 4: Run client tests**

```bash
mix test test/shem/mcp/client_test.exs
```

Expected: 5 tests, 0 failures.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: all tests passing.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/mcp/client.ex test/shem/mcp/client_test.exs
git commit -m "feat: Shem.MCP.Client — public API: call/3, list_tools/1, connected_servers/0"
```

---

## Task 8: Application wiring and config

**Files:**
- Modify: `lib/shem/application.ex`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Update `mcp_children/0` in `application.ex`**

Open `lib/shem/application.ex`. Change `mcp_children/0`:

```elixir
  defp mcp_children do
    if Application.get_env(:shem, :start_mcp, true) do
      [Shem.MCP.Server, Shem.MCP.Client.Supervisor]
    else
      []
    end
  end
```

- [ ] **Step 2: Update `config/dev.exs`**

Open `config/dev.exs`. Add the two new config keys:

```elixir
import Config

config :shem, start_tui: true
config :shem, mcp_port: 4000
config :shem, mcp_clients: []
config :shem, mcp_client_timeout_ms: 5_000
```

- [ ] **Step 3: Update `config/test.exs`**

Open `config/test.exs`. Add the two new config keys:

```elixir
import Config

config :shem, start_tui: false
config :shem, start_mcp: false
config :shem, event_log_store: Shem.EventLog.FakeStore
config :shem, lab_dir: "tmp/test_lab"
config :shem, executor_timeout_ms: 200
config :shem, mcp_port: 4001
config :shem, mcp_clients: []
config :shem, mcp_client_timeout_ms: 200
```

- [ ] **Step 4: Run full test suite**

```bash
mix test
```

Expected: all tests passing.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/application.ex config/dev.exs config/test.exs
git commit -m "feat: wire Shem.MCP.Client.Supervisor into Application supervision tree"
```

---

## Task 9: TUI dashboard update

**Files:**
- Modify: `lib/shem/tui/app.ex`
- Modify: `lib/shem/tui/views/dashboard.ex`
- Modify: `test/shem/tui/views/dashboard_test.exs`

- [ ] **Step 1: Write failing test — update `dashboard_test.exs`**

Open `test/shem/tui/views/dashboard_test.exs`.

Change `base_model/0` to add `mcp_outbound_count: 0`:

```elixir
  defp base_model do
    %{
      mode: :dashboard,
      command_buffer: "",
      paused: false,
      event_log_stats: %{sessions: 0, total_events: 0},
      tool_count: 0,
      mcp_client_count: 0,
      mcp_outbound_count: 0
    }
  end
```

Add a new test:

```elixir
  test "render/1 shows mcp_outbound_count in client stat line" do
    model = %{base_model() | mcp_outbound_count: 2}
    rendered = Dashboard.render(model) |> inspect(limit: :infinity)
    assert rendered =~ "MCP clients"
    assert rendered =~ "2"
  end
```

- [ ] **Step 2: Run dashboard tests to verify the new test fails**

```bash
mix test test/shem/tui/views/dashboard_test.exs 2>&1 | tail -10
```

Expected: 1 failure — `mcp_outbound_count` key missing or label not present.

- [ ] **Step 3: Update `dashboard.ex` to add the new stat line**

Open `lib/shem/tui/views/dashboard.ex`. Inside the `panel(title: "Lab Status", ...)` block, add a new label after the MCP server line:

```elixir
            label(
              content: "MCP clients: #{model.mcp_outbound_count} connected",
              color: color(:cyan)
            )
```

The full Lab Status panel should read:

```elixir
        column(size: 4) do
          panel(title: "Lab Status", color: color(:magenta)) do
            label(content: "Tools graduated: #{model.tool_count}", color: color(:white))

            label(
              content:
                "MCP: localhost:#{Application.get_env(:shem, :mcp_port, 4000)} — #{model.mcp_client_count} connected",
              color: color(:cyan)
            )

            label(
              content: "MCP clients: #{model.mcp_outbound_count} connected",
              color: color(:cyan)
            )

            label(
              content:
                "Sessions: #{model.event_log_stats.sessions}   Events: #{model.event_log_stats.total_events}",
              color: color(:white)
            )

            label(content: "")

            label(
              content: "Lab: idle",
              attributes: [attribute(:bold)],
              color: color(:magenta)
            )
          end
        end
```

- [ ] **Step 4: Run dashboard tests**

```bash
mix test test/shem/tui/views/dashboard_test.exs
```

Expected: all tests passing (including the new one).

- [ ] **Step 5: Update `app.ex` to populate `mcp_outbound_count` in the model**

Open `lib/shem/tui/app.ex`.

In `init/1`, add `mcp_outbound_count: 0` to the initial model:

```elixir
  @impl true
  def init(_context) do
    %{
      mode: :dashboard,
      command_buffer: "",
      paused: false,
      event_log_stats: %{sessions: 0, total_events: 0},
      tool_count: 0,
      mcp_client_count: 0,
      mcp_outbound_count: 0
    }
  end
```

In `update/2`, update the `:tick` clause to also set `mcp_outbound_count`:

```elixir
      :tick ->
        %{
          model
          | event_log_stats: safe_stats(),
            tool_count: safe_tool_count(),
            mcp_client_count: safe_mcp_count(),
            mcp_outbound_count: safe_mcp_outbound_count()
        }
```

Add the new private function at the bottom of `app.ex`:

```elixir
  defp safe_mcp_outbound_count do
    try do
      Shem.MCP.Client.connected_servers()
      |> Enum.count(&(&1.status == :ready))
    catch
      :exit, _ -> 0
    end
  end
```

- [ ] **Step 6: Run full test suite**

```bash
mix test
```

Expected: all tests passing.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/tui/app.ex lib/shem/tui/views/dashboard.ex test/shem/tui/views/dashboard_test.exs
git commit -m "feat: TUI dashboard shows MCP client count (outbound connected servers)"
```

---

## Final verification

- [ ] **Run the complete test suite one last time**

```bash
mix test
```

Expected: all tests passing, no warnings about undefined functions.

- [ ] **Verify compilation is clean**

```bash
mix compile --warnings-as-errors
```

Expected: compiled with no warnings.
