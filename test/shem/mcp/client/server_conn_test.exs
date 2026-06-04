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
