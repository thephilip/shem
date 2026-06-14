defmodule Shem.MCP.Handlers.SpawnAgentTest do
  use ExUnit.Case, async: false

  alias Shem.LLM.{Response, StubTransport}
  alias Shem.MCP.Handlers.{AgentCommon, SpawnAgent}

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

  defp stop_by_session(session_id) do
    case AgentCommon.find_by_session(session_id) do
      {:ok, name} -> Shem.Agent.stop(name)
      :not_found -> :ok
    end
  end

  test "spawns an agent and returns its session_id as agent_id, status running" do
    stub("done")
    assert {:ok, %{"agent_id" => agent_id, "status" => "running"}} =
             SpawnAgent.call(%{"goal" => "say hello"})

    on_exit(fn -> stop_by_session(agent_id) end)
    assert String.starts_with?(agent_id, "ses_")
    assert {:ok, _name} = AgentCommon.find_by_session(agent_id)
  end

  test "accepts an optional preset" do
    stub("done")
    assert {:ok, %{"agent_id" => agent_id}} =
             SpawnAgent.call(%{"goal" => "say hello", "preset" => "coder"})

    on_exit(fn -> stop_by_session(agent_id) end)
    assert {:ok, _name} = AgentCommon.find_by_session(agent_id)
  end

  test "rejects an unknown preset" do
    assert {:error, :invalid_args, msg} =
             SpawnAgent.call(%{"goal" => "x", "preset" => "no_such_preset"})

    assert msg =~ "no_such_preset"
  end

  test "rejects a missing goal" do
    assert {:error, :invalid_args, _} = SpawnAgent.call(%{})
  end

  test "accepts placement: any without error" do
    stub("done")
    assert {:ok, %{"agent_id" => agent_id}} =
             SpawnAgent.call(%{"goal" => "test placement", "placement" => "any"})

    on_exit(fn -> stop_by_session(agent_id) end)
    assert String.starts_with?(agent_id, "ses_")
  end

  test "rejects unknown placement format" do
    result = SpawnAgent.call(%{"goal" => "test", "placement" => "badformat"})
    assert {:error, :invalid_args, _} = result
  end
end
