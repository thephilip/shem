defmodule Shem.MCP.Handlers.ListAgentsTest do
  use ExUnit.Case, async: false

  alias Shem.Agent
  alias Shem.LLM.{Response, StubTransport}
  alias Shem.MCP.Handlers.ListAgents

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

  test "lists a live agent with its goal, status, and event count" do
    stub("done")
    config = %Agent.Config{task: "a distinctive goal", system_prompt: "be helpful"}
    {:ok, name, session_id} = Agent.start(config)
    {:ok, :done} = Agent.await(name, 2_000)
    on_exit(fn -> Agent.stop(name) end)

    assert {:ok, %{"agents" => agents}} = ListAgents.call(%{})
    entry = Enum.find(agents, &(&1["agent_id"] == session_id))
    assert entry
    assert entry["status"] == "done"
    assert entry["goal"] == "a distinctive goal"
    assert entry["events"] > 0
  end

  test "a stopped agent disappears from the list" do
    stub("done")
    config = %Agent.Config{task: "ephemeral", system_prompt: "be helpful"}
    {:ok, name, session_id} = Agent.start(config)
    {:ok, :done} = Agent.await(name, 2_000)
    :ok = Agent.stop(name)

    # Horde.Registry deregisters asynchronously after process death — retry briefly
    eventually(fn ->
      {:ok, %{"agents" => agents}} = ListAgents.call(%{})
      not Enum.any?(agents, &(&1["agent_id"] == session_id))
    end)
  end

  test "each agent entry includes a node field" do
    stub("done")
    config = %Agent.Config{task: "test mcp node field", system_prompt: "be helpful"}
    {:ok, name, session_id} = Agent.start(config)
    {:ok, :done} = Agent.await(name, 2_000)
    on_exit(fn -> Agent.stop(name) end)

    {:ok, result} = ListAgents.call(%{})
    agents = result["agents"]

    entry = Enum.find(agents, &(&1["agent_id"] == session_id))
    assert entry, "expected to find agent with session_id #{session_id}"
    assert Map.has_key?(entry, "node"), "expected node field in #{inspect(entry)}"
    assert is_binary(entry["node"])
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
