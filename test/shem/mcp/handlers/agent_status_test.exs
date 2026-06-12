defmodule Shem.MCP.Handlers.AgentStatusTest do
  use ExUnit.Case, async: false

  alias Shem.Agent
  alias Shem.LLM.{Response, StubTransport}
  alias Shem.MCP.Handlers.AgentStatus

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

  test "live done agent: status done with final output and event count" do
    stub("the final answer")
    config = %Agent.Config{task: "compute", system_prompt: "be helpful"}
    {:ok, name, session_id} = Agent.start(config)
    {:ok, :done} = Agent.await(name, 2_000)
    on_exit(fn -> Agent.stop(name) end)

    assert {:ok, result} = AgentStatus.call(%{"agent_id" => session_id})
    assert result["agent_id"] == session_id
    assert result["status"] == "done"
    assert result["output"] == "the final answer"
    assert result["events"] > 0
  end

  test "live conversational agent: status waiting with last content" do
    stub("how can I help?")
    config = %Agent.Config{task: "chat", system_prompt: "be helpful", conversational: true}
    {:ok, name, session_id} = Agent.start(config)
    {:ok, :waiting} = Agent.await(name, 2_000)
    on_exit(fn -> Agent.stop(name) end)

    assert {:ok, result} = AgentStatus.call(%{"agent_id" => session_id})
    assert result["status"] == "waiting"
    assert result["output"] == "how can I help?"
  end

  test "dead agent: tombstone status from EventLog" do
    stub("posthumous answer")
    config = %Agent.Config{task: "die", system_prompt: "be helpful"}
    {:ok, name, session_id} = Agent.start(config)
    {:ok, :done} = Agent.await(name, 2_000)
    :ok = Agent.stop(name)

    assert {:ok, result} = AgentStatus.call(%{"agent_id" => session_id})
    assert result["status"] == "done"
    assert result["output"] == "posthumous answer"
  end

  test "unknown agent_id returns not_found error" do
    assert {:error, :not_found, _} = AgentStatus.call(%{"agent_id" => "ses_NOPE"})
  end

  test "missing agent_id is invalid_args" do
    assert {:error, :invalid_args, _} = AgentStatus.call(%{})
  end
end
