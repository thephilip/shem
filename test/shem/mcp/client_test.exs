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
    # Wait for :ready status
    assert :ready = GenServer.call(conn, :status)

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

    # connected_servers reads Horde.Registry, which is eventually consistent —
    # poll briefly instead of asserting a raw snapshot (codebase convention,
    # see agent_common_test)
    eventually(fn ->
      Client.connected_servers()
      |> Enum.any?(&(&1.name == "test-fs3" and &1.status == :ready))
    end)
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end
end
