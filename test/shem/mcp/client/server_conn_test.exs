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
             Horde.Registry.lookup(Shem.Registry, {ServerConn, "t6"})
  end

  describe "call/response correlation" do
    test "call returns {:ok, result} when server responds correctly" do
      conn = start_conn("c1")
      drive_handshake(conn)
      fake_pid = self()

      task = Task.async(fn ->
        GenServer.call(conn, {:call, "read_file", %{"path" => "/tmp/x"}, 1_000})
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

      task1 = Task.async(fn -> GenServer.call(conn, {:call, "tool_a", %{}, 1_000}) end)
      task2 = Task.async(fn -> GenServer.call(conn, {:call, "tool_b", %{}, 1_000}) end)

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

      task = Task.async(fn -> GenServer.call(conn, {:call, "bad_tool", %{}, 1_000}) end)

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
      assert {:error, :not_ready} = GenServer.call(conn, {:call, "tool", %{}, 1_000})
    end
  end

  describe "error paths" do
    test "malformed stdout line is skipped, ServerConn does not crash" do
      conn = start_conn("e1")
      drive_handshake(conn)
      fake_pid = self()

      send(conn, {fake_pid, {:data, {:eol, "not json at all"}}})

      # ServerConn is still alive
      assert Process.alive?(conn)
      assert :ready = GenServer.call(conn, :status)
    end

    test "oversized line (noeol) is skipped, ServerConn does not crash" do
      conn = start_conn("e2")
      drive_handshake(conn)
      fake_pid = self()

      send(conn, {fake_pid, {:data, {:noeol, "x"}}})

      assert Process.alive?(conn)
      assert :ready = GenServer.call(conn, :status)
    end

    test "port exit_status sends :server_down to in-flight callers" do
      conn = start_conn("e3")
      drive_handshake(conn)
      fake_pid = self()

      task = Task.async(fn ->
        GenServer.call(conn, {:call, "slow_tool", %{}, 2_000}, 2_500)
      end)

      # Wait for the port_write
      assert_receive {:port_write, ^conn, _}, 500

      # Simulate OS process exit
      Process.flag(:trap_exit, true)
      send(conn, {fake_pid, {:exit_status, 1}})

      assert {:error, :server_down} = Task.await(task, 1_000)
    end
  end
end
