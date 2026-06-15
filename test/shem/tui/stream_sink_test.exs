defmodule Shem.TUI.StreamSinkTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.StreamSink

  setup do
    session_id = "test_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = StreamSink.start_link(session_id)
    %{pid: pid, session_id: session_id}
  end

  test "take_thinking returns nil before any thinking arrives", %{pid: pid} do
    assert StreamSink.take_thinking(pid) == nil
  end

  test "take_thinking returns stored thinking and then nil", %{pid: pid, session_id: sid} do
    send(pid, {:stream_thinking, sid, "I need to reason about this"})
    :timer.sleep(10)
    assert StreamSink.take_thinking(pid) == "I need to reason about this"
    assert StreamSink.take_thinking(pid) == nil
  end

  test "second stream_thinking replaces the first", %{pid: pid, session_id: sid} do
    send(pid, {:stream_thinking, sid, "first"})
    send(pid, {:stream_thinking, sid, "second"})
    :timer.sleep(10)
    assert StreamSink.take_thinking(pid) == "second"
  end

  test "take_tokens still works alongside take_thinking", %{pid: pid, session_id: sid} do
    send(pid, {:stream_chunk, sid, "hello"})
    send(pid, {:stream_thinking, sid, "thinking..."})
    :timer.sleep(10)
    assert StreamSink.take_tokens(pid) == ["hello"]
    assert StreamSink.take_thinking(pid) == "thinking..."
  end
end
