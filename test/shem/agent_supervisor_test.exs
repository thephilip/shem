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

  test "a crashed agent is NOT restarted (:temporary restart strategy)" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    config = %Agent.Config{task: "t", system_prompt: "s"}
    name = "test_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = AgentSupervisor.start_agent(name, config)
    Process.exit(pid, :kill)
    # Horde registry cleanup is async — give it time
    Process.sleep(300)
    via = Shem.ProcessRegistry.via_tuple(name)
    assert GenServer.whereis(via) == nil
  end

  test "Shadow.Agent is NOT spawned when shadow_agent_enabled is false" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    config = %Shem.Agent.Config{task: "t", system_prompt: "s"}
    agent_name = "sa_shadow_test_#{System.unique_integer([:positive])}"
    session_id = "ses_shadow_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Shem.AgentSupervisor.start_agent(agent_name, config, session_id)

    # shadow_agent_enabled: false in test env — no shadow agent spawns
    assert Shem.Shadow.Agent.current_score(agent_name) == {:error, :not_found}
  end
end
