defmodule Shem.AgentSupervisorTest do
  use ExUnit.Case, async: false

  alias Shem.{Agent, AgentSupervisor}

  setup do
    Shem.LLM.BudgetServer.reset()
    Shem.LLM.StubTransport.Server.reset()
    lab_dir = Application.get_env(:shem, :lab_dir)
    on_exit(fn ->
      File.rm_rf!(lab_dir)
      Shem.Lab.Registry.flush()
    end)
    :ok
  end

  test "start_agent/2 starts a live Agent.Server process" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    config = %Agent.Config{task: "t", system_prompt: "s"}
    name = "test_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = AgentSupervisor.start_agent(name, config)
    assert Process.alive?(pid)
  end

  test "started agent registers in Shem.Registry under its name" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    config = %Agent.Config{task: "t", system_prompt: "s"}
    name = "test_agent_#{System.unique_integer([:positive])}"
    AgentSupervisor.start_agent(name, config)
    via = Shem.ProcessRegistry.via_tuple(name)
    assert is_pid(GenServer.whereis(via))
  end

  test "a crashed agent is NOT restarted (temporary restart)" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    config = %Agent.Config{task: "t", system_prompt: "s"}
    name = "test_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = AgentSupervisor.start_agent(name, config)
    Process.exit(pid, :kill)
    Process.sleep(100)
    via = Shem.ProcessRegistry.via_tuple(name)
    assert GenServer.whereis(via) == nil
  end
end
