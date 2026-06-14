defmodule Shem.TUI.StreamSinkTest do
  use ExUnit.Case, async: false

  alias Shem.TUI.StreamSink

  setup do
    case :pg.start_link(:shem_streams) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
    :ok
  end

  test "init/1 joins :pg group for session" do
    session_id = "ses_test_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = StreamSink.start_link(session_id)

    members = :pg.get_members(:shem_streams, session_id)
    assert pid in members

    StreamSink.stop(pid)
  end

  test "receives :stream_chunk tokens and buffers them" do
    session_id = "ses_test_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = StreamSink.start_link(session_id)

    send(pid, {:stream_chunk, session_id, "hello"})
    send(pid, {:stream_chunk, session_id, " world"})
    Process.sleep(10)

    assert StreamSink.take_tokens(pid) == ["hello", " world"]

    StreamSink.stop(pid)
  end

  test "take_tokens/1 drains the buffer" do
    session_id = "ses_test_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = StreamSink.start_link(session_id)

    send(pid, {:stream_chunk, session_id, "token"})
    Process.sleep(10)

    assert StreamSink.take_tokens(pid) == ["token"]
    assert StreamSink.take_tokens(pid) == []

    StreamSink.stop(pid)
  end

  test "process death removes it from :pg group" do
    session_id = "ses_test_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = StreamSink.start_link(session_id)
    ref = Process.monitor(pid)

    assert pid in :pg.get_members(:shem_streams, session_id)

    StreamSink.stop(pid)
    receive do {:DOWN, ^ref, _, _, _} -> :ok after 1000 -> flunk("process didn't stop") end
    # :pg removes dead processes asynchronously; give it a moment
    Process.sleep(20)

    assert pid not in :pg.get_members(:shem_streams, session_id)
  end
end
