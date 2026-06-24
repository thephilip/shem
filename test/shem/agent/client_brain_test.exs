defmodule Shem.Agent.ClientBrainTest do
  use ExUnit.Case, async: false
  alias Shem.Agent

  setup do
    # client brain calls no real LLM; ensure no terminal transport is needed.
    :ok
  end

  test "client agent parks, runs a tool turn, then finishes" do
    {:ok, _name, sid} =
      Agent.start_with_preset("general", "double the number 4", brain: :client)

    # Parks shortly after spawn
    name = wait_for_awaiting(sid)
    {:ok, info} = Agent.info(name)
    assert info.status == :awaiting_turn
    assert is_binary(info.awaiting_prompt)
    token = info.turn_token

    # Stale token rejected
    assert {:error, :stale_turn} = Agent.provide_turn(name, {:bogus, 0}, "hi")

    # Provide a tool-call turn (JSON-in-prose, as the prompt instructs)
    {:ok, after_tool} =
      Agent.provide_turn(name, token, ~s({"tool":"execute_code","args":{"code":"IO.puts 8"}}))
    assert after_tool.status == :awaiting_turn
    refute after_tool.turn_token == token  # new token after re-park

    # Provide a final (plain text, no tool JSON)
    {:ok, done} = Agent.provide_turn(name, after_tool.turn_token, "The answer is 8.")
    assert done.status == :done
    assert done.output =~ "8"
  end

  test "conversational client agent: a finishing turn reports :waiting, does not crash" do
    {:ok, _name, sid} =
      Agent.start_with_preset("general", "say hi", brain: :client, conversational: true)

    name = wait_for_awaiting(sid)
    {:ok, info} = Agent.info(name)
    {:ok, res} = Agent.provide_turn(name, info.turn_token, "Hello there.")
    assert res.status == :waiting
    assert res.output =~ "Hello"
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
