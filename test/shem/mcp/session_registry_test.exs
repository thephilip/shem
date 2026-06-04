defmodule Shem.MCP.SessionRegistryTest do
  use ExUnit.Case, async: true

  alias Shem.MCP.SessionRegistry

  test "client_count starts at 0" do
    {:ok, pid} = start_supervised({SessionRegistry, name: :test_sr_1})
    assert 0 = GenServer.call(pid, :client_count)
  end

  test "register_session increments client_count" do
    {:ok, pid} = start_supervised({SessionRegistry, name: :test_sr_2})
    GenServer.call(pid, {:register, "sess-1", self()})
    assert 1 = GenServer.call(pid, :client_count)
  end

  test "unregister_session decrements client_count" do
    {:ok, pid} = start_supervised({SessionRegistry, name: :test_sr_3})
    GenServer.call(pid, {:register, "sess-1", self()})
    GenServer.call(pid, {:unregister, "sess-1"})
    assert 0 = GenServer.call(pid, :client_count)
  end

  test "send_to_session delivers a message to the registered pid" do
    {:ok, pid} = start_supervised({SessionRegistry, name: :test_sr_4})
    GenServer.call(pid, {:register, "sess-1", self()})
    GenServer.call(pid, {:send, "sess-1", %{"hello" => "world"}})
    assert_receive {:mcp_response, %{"hello" => "world"}}
  end

  test "send_to_session returns error for unknown session" do
    {:ok, pid} = start_supervised({SessionRegistry, name: :test_sr_5})
    assert {:error, :not_found} = GenServer.call(pid, {:send, "ghost", %{}})
  end

  test "dead session processes are cleaned up automatically" do
    {:ok, pid} = start_supervised({SessionRegistry, name: :test_sr_6})
    session_pid = spawn(fn -> receive do: (:stop -> :ok) end)
    GenServer.call(pid, {:register, "sess-1", session_pid})
    send(session_pid, :stop)
    Process.sleep(20)
    assert 0 = GenServer.call(pid, :client_count)
  end
end
