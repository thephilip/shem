defmodule Shem.TUI.AgentViewTest do
  use ExUnit.Case, async: false

  alias Shem.TUI.AgentView
  alias Shem.EventLog

  defp open(id) do
    {:ok, ^id} = EventLog.start_session(id)
    id
  end

  defp session_id, do: "ses_AGVIEW_#{System.unique_integer([:positive])}"

  describe "build/1" do
    test "returns :not_found for empty session" do
      id = open(session_id())
      assert :not_found = AgentView.build(id)
    end

    test "returns :not_found for non-existent session" do
      assert :not_found = AgentView.build("ses_DOES_NOT_EXIST_XYZ")
    end

    test "returns {:ok, view} after agent_started event" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "do something", model: :default, max_turns: 15})
      assert {:ok, view} = AgentView.build(id)
      assert view.max_turns == 15
      assert view.status == :running
      assert view.turn_count == 0
    end

    test "turn_count increments on agent_turn_started" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "t", model: :default, max_turns: 20})
      EventLog.append(id, :agent_turn_started, %{turn: 1})
      EventLog.append(id, :agent_turn_started, %{turn: 2})
      assert {:ok, view} = AgentView.build(id)
      assert view.turn_count == 2
    end

    test "current_reasoning is set from llm_call_completed" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "t", model: :default, max_turns: 20})
      EventLog.append(id, :agent_turn_started, %{turn: 1})
      EventLog.append(id, :llm_call_completed, %{content: "I will read the file first.", tokens_used: 5, model: :default, latency_ms: 100})
      assert {:ok, view} = AgentView.build(id)
      assert view.current_reasoning == "I will read the file first."
    end

    test "last_tool_call is populated from tool_called and tool_result events" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "t", model: :default, max_turns: 20})
      EventLog.append(id, :agent_turn_started, %{turn: 1})
      EventLog.append(id, :agent_tool_called, %{tool: "read_file", args: %{"path" => "lib/foo.ex"}})
      EventLog.append(id, :agent_tool_result, %{tool: "read_file", result: "defmodule Foo do"})
      assert {:ok, view} = AgentView.build(id)
      assert view.last_tool_call.name == "read_file"
      assert view.last_tool_call.result == "defmodule Foo do"
    end

    test "history accumulates completed turns" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "t", model: :default, max_turns: 20})
      EventLog.append(id, :agent_turn_started, %{turn: 1})
      EventLog.append(id, :agent_tool_called, %{tool: "read_file", args: %{}})
      EventLog.append(id, :agent_turn_completed, %{turn: 1, outcome: :tool_calls})
      EventLog.append(id, :agent_turn_started, %{turn: 2})
      EventLog.append(id, :agent_turn_completed, %{turn: 2, outcome: :done})
      assert {:ok, view} = AgentView.build(id)
      assert length(view.history) == 2
      assert hd(view.history).tool == "read_file"
    end

    test "status becomes :done on agent_done event" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "t", model: :default, max_turns: 20})
      EventLog.append(id, :agent_done, %{reason: :answer})
      assert {:ok, view} = AgentView.build(id)
      assert view.status == :done
    end

    test "status becomes :error on agent_error event" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "t", model: :default, max_turns: 20})
      EventLog.append(id, :agent_error, %{reason: "llm failed"})
      assert {:ok, view} = AgentView.build(id)
      assert view.status == :error
    end

    test "recent_events contains last event types (capped at 10)" do
      id = open(session_id())
      EventLog.append(id, :agent_started, %{task: "t", model: :default, max_turns: 20})
      for i <- 1..12 do
        EventLog.append(id, :agent_turn_started, %{turn: i})
      end
      assert {:ok, view} = AgentView.build(id)
      assert length(view.recent_events) == 10
      assert List.last(view.recent_events) == :agent_turn_started
    end
  end
end
