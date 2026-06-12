defmodule Shem.MCP.AgentToolsIntegrationTest do
  use ExUnit.Case, async: false

  alias Shem.LLM.{Response, StubTransport}
  alias Shem.MCP.Handlers.{AgentStatus, SpawnAgent, StopAgent}

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

  defp poll_until_done(agent_id, attempts \\ 50) do
    Enum.reduce_while(1..attempts, %{"status" => "timeout"}, fn _, last ->
      case AgentStatus.call(%{"agent_id" => agent_id}) do
        {:ok, %{"status" => s} = result} when s in ["done", "error"] ->
          {:halt, result}

        _ ->
          Process.sleep(50)
          {:cont, last}
      end
    end)
  end

  test "two agents spawned in parallel both complete with their own results" do
    # StubTransport is a FIFO queue shared by all agents; push one answer per agent
    stub("answer alpha")
    stub("answer beta")

    {:ok, %{"agent_id" => id_a}} = SpawnAgent.call(%{"goal" => "task alpha"})
    {:ok, %{"agent_id" => id_b}} = SpawnAgent.call(%{"goal" => "task beta"})

    on_exit(fn ->
      StopAgent.call(%{"agent_id" => id_a})
      StopAgent.call(%{"agent_id" => id_b})
    end)

    result_a = poll_until_done(id_a)
    result_b = poll_until_done(id_b)

    assert result_a["status"] == "done",
           "agent A did not finish; last: #{inspect(result_a)}"

    assert result_b["status"] == "done",
           "agent B did not finish; last: #{inspect(result_b)}"

    # the FIFO stub assigns answers to whichever agent calls first,
    # so assert the set, not the pairing
    assert Enum.sort([result_a["output"], result_b["output"]]) ==
             ["answer alpha", "answer beta"]
  end
end
