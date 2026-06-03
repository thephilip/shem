defmodule Shem.AgentSupervisorTest do
  use ExUnit.Case, async: false

  alias Shem.AgentSupervisor

  test "start_agent/2 starts a live process under the supervisor" do
    {:ok, pid} = AgentSupervisor.start_agent(
      :"agent_#{System.unique_integer([:positive])}",
      fn -> :idle end
    )
    assert Process.alive?(pid)
  end

  test "start_agent/2 registers the process by name in Shem.Registry" do
    name = :"named_#{System.unique_integer([:positive])}"
    {:ok, _pid} = AgentSupervisor.start_agent(name, fn -> 42 end)

    via = Shem.ProcessRegistry.via_tuple(name)
    pid = GenServer.whereis(via)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "a supervised agent process is restarted when it crashes" do
    name = :"crash_#{System.unique_integer([:positive])}"
    {:ok, pid} = AgentSupervisor.start_agent(name, fn -> :ok end)

    Process.exit(pid, :kill)
    Process.sleep(100)

    via = Shem.ProcessRegistry.via_tuple(name)
    new_pid = GenServer.whereis(via)
    assert is_pid(new_pid)
    assert new_pid != pid
  end
end
