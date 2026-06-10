defmodule Shem.Shadow.PromptTest do
  use ExUnit.Case, async: true

  alias Shem.Shadow.Prompt
  alias Shem.EventLog.Event

  defp make_event(type, payload) do
    %Event{id: 1, session_id: "test", parent_id: nil, type: type, payload: payload, timestamp: DateTime.utc_now()}
  end

  test "build/2 returns task header when no checkpoint events exist" do
    result = Prompt.build("fix the bug", [])
    assert result =~ "Task: fix the bug"
  end

  test "build/2 uses latest checkpoint history" do
    checkpoint = make_event(:agent_checkpoint, %{
      history: [
        %{role: :user, content: "fix the bug"},
        %{role: :assistant, content: "I'll look at the code."}
      ],
      turn_count: 1,
      config: %{}
    })
    result = Prompt.build("fix the bug", [checkpoint])
    assert result =~ "user: fix the bug"
    assert result =~ "assistant: I'll look at the code."
  end

  test "build/2 formats tool call assistant entries" do
    checkpoint = make_event(:agent_checkpoint, %{
      history: [
        %{role: :assistant, content: nil, tool_calls: [%{id: "1", name: "read_file", args: %{"path" => "/src/foo.ex"}}]}
      ],
      turn_count: 1,
      config: %{}
    })
    result = Prompt.build("task", [checkpoint])
    assert result =~ "assistant: [tool calls: read_file]"
  end

  test "build/2 formats tool result entries" do
    checkpoint = make_event(:agent_checkpoint, %{
      history: [
        %{role: :tool, tool_call_id: "1", content: "Tool result (read_file): contents here"}
      ],
      turn_count: 1,
      config: %{}
    })
    result = Prompt.build("task", [checkpoint])
    assert result =~ "tool_result: Tool result (read_file): contents here"
  end

  test "build/2 truncates to last 20 history entries" do
    entries = Enum.map(1..25, fn i -> %{role: :user, content: "message #{i}"} end)
    checkpoint = make_event(:agent_checkpoint, %{history: entries, turn_count: 25, config: %{}})
    result = Prompt.build("task", [checkpoint])
    # Use exact line matching to avoid substring collisions (e.g. "message 1" ⊂ "message 10")
    lines = String.split(result, "\n")
    refute "user: message 1" in lines
    refute "user: message 5" in lines
    assert "user: message 6" in lines
    assert "user: message 25" in lines
  end

  test "build/2 uses the latest of multiple checkpoint events" do
    old_checkpoint = make_event(:agent_checkpoint, %{
      history: [%{role: :user, content: "old message"}], turn_count: 1, config: %{}
    })
    new_checkpoint = make_event(:agent_checkpoint, %{
      history: [%{role: :user, content: "new message"}], turn_count: 2, config: %{}
    })
    result = Prompt.build("task", [old_checkpoint, new_checkpoint])
    assert result =~ "new message"
    refute result =~ "old message"
  end

  test "system_prompt/0 returns non-empty string with JSON instruction" do
    sp = Prompt.system_prompt()
    assert is_binary(sp)
    assert sp =~ "JSON"
    assert sp =~ "score"
    assert sp =~ "reasoning"
  end
end
