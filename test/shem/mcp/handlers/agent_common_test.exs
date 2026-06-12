defmodule Shem.MCP.Handlers.AgentCommonTest do
  use ExUnit.Case, async: false

  alias Shem.Agent
  alias Shem.LLM.{Response, StubTransport}
  alias Shem.MCP.Handlers.AgentCommon

  setup do
    Shem.LLM.BudgetServer.reset()
    StubTransport.Server.reset()
    :ok
  end

  defp stub(content) do
    StubTransport.Server.push_response(
      {:ok, %Response{content: content, tokens_used: 5, model: :default, latency_ms: 1}}
    )
  end

  defp start_done_agent(task) do
    stub("all done")
    config = %Agent.Config{task: task, system_prompt: "be helpful"}
    {:ok, name, session_id} = Agent.start(config)
    {:ok, :done} = Agent.await(name, 2_000)
    {name, session_id}
  end

  describe "find_by_session/1" do
    test "finds a live agent's name by its session_id" do
      {name, session_id} = start_done_agent("find me")
      on_exit(fn -> Agent.stop(name) end)
      assert {:ok, ^name} = AgentCommon.find_by_session(session_id)
    end

    test "returns :not_found for an unknown session_id" do
      assert :not_found = AgentCommon.find_by_session("ses_DOESNOTEXIST")
    end

    test "returns :not_found after the agent process is stopped" do
      {name, session_id} = start_done_agent("stop me")
      :ok = Agent.stop(name)
      eventually(fn -> AgentCommon.find_by_session(session_id) == :not_found end)
    end
  end

  describe "live_agents/0" do
    test "includes a started agent as {name, session_id}" do
      {name, session_id} = start_done_agent("list me")
      on_exit(fn -> Agent.stop(name) end)
      assert {name, session_id} in AgentCommon.live_agents()
    end
  end

  describe "event extraction" do
    test "goal/1 returns the task from :agent_started" do
      {name, session_id} = start_done_agent("the goal text")
      on_exit(fn -> Agent.stop(name) end)
      {:ok, events} = AgentCommon.session_events(session_id)
      assert AgentCommon.goal(events) == "the goal text"
    end

    test "final_output/1 returns the :agent_done answer content" do
      {name, session_id} = start_done_agent("answer me")
      on_exit(fn -> Agent.stop(name) end)
      {:ok, events} = AgentCommon.session_events(session_id)
      assert AgentCommon.final_output(events) == "all done"
    end

    test "tombstone_status/1 is done for a completed session" do
      {name, session_id} = start_done_agent("tombstone")
      :ok = Agent.stop(name)
      {:ok, events} = AgentCommon.session_events(session_id)
      assert AgentCommon.tombstone_status(events) == "done"
    end

    test "session_events/1 returns :not_found for unknown session" do
      assert {:error, :not_found} = AgentCommon.session_events("ses_NOPE")
    end
  end

  # Horde.Registry deregisters asynchronously after process death — retry briefly
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
