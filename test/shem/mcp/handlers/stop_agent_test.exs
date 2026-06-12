defmodule Shem.MCP.Handlers.StopAgentTest do
  use ExUnit.Case, async: false

  alias Shem.Agent
  alias Shem.LLM.{Response, StubTransport}
  alias Shem.MCP.Handlers.{AgentCommon, StopAgent}

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

  test "stops a live agent by session_id" do
    stub("done")
    config = %Agent.Config{task: "stoppable", system_prompt: "be helpful"}
    {:ok, name, session_id} = Agent.start(config)
    {:ok, :done} = Agent.await(name, 2_000)

    assert {:ok, %{"ok" => true}} = StopAgent.call(%{"agent_id" => session_id})
    # Horde.Registry deregisters asynchronously after process death — retry briefly
    eventually(fn -> AgentCommon.find_by_session(session_id) == :not_found end)
  end

  test "unknown agent_id returns not_found error" do
    assert {:error, :not_found, _} = StopAgent.call(%{"agent_id" => "ses_NOPE"})
  end

  test "missing agent_id is invalid_args" do
    assert {:error, :invalid_args, _} = StopAgent.call(%{})
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
