defmodule Shem.MCP.ProvideTurnTest do
  use ExUnit.Case, async: false
  alias Shem.MCP.Handlers.{SpawnAgent, AgentStatus, ProvideTurn}

  test "spawn client agent, read prompt+token via status, provide a final turn" do
    {:ok, %{"agent_id" => sid}} = SpawnAgent.call(%{"goal" => "say hi", "brain" => "client"})
    token = await_token(sid)
    {:ok, res} = ProvideTurn.call(%{"agent_id" => sid, "turn_token" => token, "content" => "hi there"})
    assert res["status"] in ["done", "awaiting_turn"]
  end

  test "rejects forged, legacy-format, and cross-agent tokens" do
    {:ok, %{"agent_id" => sid_a}} = SpawnAgent.call(%{"goal" => "a", "brain" => "client"})
    {:ok, %{"agent_id" => sid_b}} = SpawnAgent.call(%{"goal" => "b", "brain" => "client"})
    token_a = await_token(sid_a)
    _token_b = await_token(sid_b)

    # legacy plain format is no longer accepted
    assert {:error, :invalid_args, _} =
             ProvideTurn.call(%{"agent_id" => sid_a, "turn_token" => "1:123", "content" => "x"})

    # tampered signature
    assert {:error, :invalid_args, _} =
             ProvideTurn.call(%{"agent_id" => sid_a, "turn_token" => token_a <> "x", "content" => "x"})

    # wrong agent: a valid token for A presented against B
    assert {:error, :invalid_args, _} =
             ProvideTurn.call(%{"agent_id" => sid_b, "turn_token" => token_a, "content" => "x"})

    # expired
    {:ok, real_sid, tuple} = Shem.TurnToken.decode(token_a)
    expired = Shem.TurnToken.encode(real_sid, tuple, ttl: -1)
    assert {:error, :invalid_args, _} =
             ProvideTurn.call(%{"agent_id" => sid_a, "turn_token" => expired, "content" => "x"})

    # the valid token still works
    {:ok, res} = ProvideTurn.call(%{"agent_id" => sid_a, "turn_token" => token_a, "content" => "done"})
    assert res["status"] in ["done", "awaiting_turn", "waiting"]
  end

  defp await_token(sid, n \\ 300)
  defp await_token(_sid, 0), do: flunk("never awaited")
  defp await_token(sid, n) do
    {:ok, st} = AgentStatus.call(%{"agent_id" => sid})
    case st["status"] do
      "awaiting_turn" -> st["turn_token"]
      _ -> Process.sleep(20); await_token(sid, n - 1)
    end
  end
end
