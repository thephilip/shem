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
    {:ok, pid, _sid} = AgentSupervisor.start_agent(name, config)
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

  test "a cleanly stopped agent is NOT restarted (:transient restart strategy)" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    config = %Agent.Config{task: "t", system_prompt: "s"}
    name = "test_agent_#{System.unique_integer([:positive])}"
    {:ok, pid, _sid} = AgentSupervisor.start_agent(name, config)
    GenServer.stop(pid, :normal)
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

  describe "placement" do
    setup do
      Shem.LLM.StubTransport.Server.set_default(
        {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
      )
      :ok
    end

    test "placement :any starts agent without placement_miss event" do
      config = %Agent.Config{task: "t", system_prompt: "s", placement: :any}
      name = "test_place_any_#{System.unique_integer([:positive])}"
      {:ok, _pid, session_id} = AgentSupervisor.start_agent(name, config)
      Process.sleep(200)
      {:ok, events} = Shem.EventLog.events(session_id)
      refute Enum.any?(events, &(&1.type == :placement_miss))
    end

    test "placement {:node, self()} starts agent successfully" do
      config = %Agent.Config{task: "t", system_prompt: "s", placement: {:node, Node.self()}}
      name = "test_place_node_#{System.unique_integer([:positive])}"
      assert {:ok, _pid, _sid} = AgentSupervisor.start_agent(name, config)
    end

    test "placement {:node, unknown} returns error" do
      config = %Agent.Config{task: "t", system_prompt: "s", placement: {:node, :"ghost@nowhere"}}
      name = "test_place_bad_#{System.unique_integer([:positive])}"
      assert {:error, :no_matching_node} = AgentSupervisor.start_agent(name, config)
    end

    test "placement {:labels, selector} with no match falls back to :any and logs placement_miss" do
      config = %Agent.Config{
        task: "t",
        system_prompt: "s",
        placement: {:labels, %{"model" => "nonexistent-model"}}
      }
      name = "test_place_label_miss_#{System.unique_integer([:positive])}"
      assert {:ok, _pid, session_id} = AgentSupervisor.start_agent(name, config)
      Process.sleep(200)
      {:ok, events} = Shem.EventLog.events(session_id)
      assert Enum.any?(events, &(&1.type == :placement_miss))
    end

    test "placement {:labels, selector, :required} with no match returns error" do
      config = %Agent.Config{
        task: "t",
        system_prompt: "s",
        placement: {:labels, %{"model" => "nonexistent-model"}, :required}
      }
      name = "test_place_label_req_#{System.unique_integer([:positive])}"
      assert {:error, :no_matching_node} = AgentSupervisor.start_agent(name, config)
    end
  end

  describe "evacuate_all/0" do
    test "flushes checkpoint for each local agent" do
      Shem.LLM.StubTransport.Server.set_default(
        {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
      )
      config = %Agent.Config{task: "say done", system_prompt: "s", conversational: true}
      name = "evac_test_#{System.unique_integer([:positive])}"
      {:ok, _pid, session_id} = AgentSupervisor.start_agent(name, config)
      # Wait for agent to reach :waiting state after first turn
      Process.sleep(300)

      AgentSupervisor.evacuate_all()

      # flush_checkpoint writes an additional checkpoint beyond the run_turn one
      {:ok, events} = Shem.EventLog.events(session_id)
      assert Enum.count(events, &(&1.type == :agent_checkpoint)) >= 2
    end
  end
end
