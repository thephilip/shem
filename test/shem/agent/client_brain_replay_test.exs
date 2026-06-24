defmodule Shem.Agent.ClientBrainReplayTest do
  use ExUnit.Case, async: false
  alias Shem.Agent

  test "a client-driven session replays without divergence" do
    {:ok, _name, sid} = Agent.start_with_preset("general", "double 4", brain: :client)
    name = wait_for_awaiting(sid)            # reuse helper from client_brain_test.exs
    {:ok, t} = Agent.info(name)
    {:ok, a} = Agent.provide_turn(name, t.turn_token, ~s[{"tool":"execute_code","args":{"code":"IO.puts(8)"}}])
    {:ok, _} = Agent.provide_turn(name, a.turn_token, "done: 8")

    {:ok, events} = Shem.EventLog.events(sid)
    completed = for e <- events, e.type == :llm_call_completed, do: e.payload[:content]
    assert length(completed) == 2
    assert Enum.any?(completed, &(&1 =~ "execute_code"))
    refute Enum.any?(events, &(&1.type == :llm_call_diverged))
  end

  defp wait_for_awaiting(sid, tries \\ 50)
  defp wait_for_awaiting(_sid, 0), do: flunk("agent never parked")
  defp wait_for_awaiting(sid, n) do
    case Shem.MCP.Handlers.AgentCommon.find_by_session(sid) do
      {:ok, name} ->
        case Agent.info(name) do
          {:ok, %{status: :awaiting_turn}} -> name
          _ -> Process.sleep(20); wait_for_awaiting(sid, n - 1)
        end
      :not_found -> Process.sleep(20); wait_for_awaiting(sid, n - 1)
    end
  end
end
