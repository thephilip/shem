defmodule Shem.MCP.ProvideTurnTest do
  use ExUnit.Case, async: false
  alias Shem.MCP.Handlers.{SpawnAgent, AgentStatus, ProvideTurn}

  test "spawn client agent, read prompt+token via status, provide a final turn" do
    {:ok, %{"agent_id" => sid}} = SpawnAgent.call(%{"goal" => "say hi", "brain" => "client"})
    token = await_token(sid)
    {:ok, res} = ProvideTurn.call(%{"agent_id" => sid, "turn_token" => token, "content" => "hi there"})
    assert res["status"] in ["done", "awaiting_turn"]
  end

  defp await_token(sid, n \\ 50)
  defp await_token(_sid, 0), do: flunk("never awaited")
  defp await_token(sid, n) do
    {:ok, st} = AgentStatus.call(%{"agent_id" => sid})
    case st["status"] do
      "awaiting_turn" -> st["turn_token"]
      _ -> Process.sleep(20); await_token(sid, n - 1)
    end
  end
end
