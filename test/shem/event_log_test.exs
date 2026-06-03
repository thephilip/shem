defmodule Shem.EventLogTest do
  use ExUnit.Case, async: false

  alias Shem.EventLog

  describe "start_session/0" do
    test "returns {:ok, session_id} where session_id starts with 'ses_'" do
      {:ok, session_id} = EventLog.start_session()
      assert String.starts_with?(session_id, "ses_")
    end

    test "each call returns a unique session_id" do
      {:ok, id1} = EventLog.start_session()
      {:ok, id2} = EventLog.start_session()
      assert id1 != id2
    end
  end

  describe "end_session/1" do
    test "returns :ok for an active session" do
      {:ok, id} = EventLog.start_session()
      assert :ok = EventLog.end_session(id)
    end

    test "returns {:error, :session_not_found} for unknown session_id" do
      assert {:error, :session_not_found} = EventLog.end_session("ses_doesnotexist00")
    end
  end

  describe "list_sessions/0" do
    test "includes the session after start_session" do
      {:ok, id} = EventLog.start_session()
      {:ok, sessions} = EventLog.list_sessions()
      assert Enum.any?(sessions, &(&1.id == id))
    end
  end

  describe "stats/0" do
    test "returns a map with :sessions and :total_events integer keys" do
      stats = EventLog.stats()
      assert is_integer(stats.sessions)
      assert is_integer(stats.total_events)
    end

    test ":sessions count increases after start_session" do
      before = EventLog.stats().sessions
      {:ok, _id} = EventLog.start_session()
      after_ = EventLog.stats().sessions
      assert after_ > before
    end
  end

  describe "append/3" do
    test "returns {:ok, %Event{}} with the correct fields" do
      {:ok, sid} = EventLog.start_session()
      {:ok, event} = EventLog.append(sid, :state_changed, %{x: 1})
      assert String.starts_with?(event.id, "evt_")
      assert event.session_id == sid
      assert event.type == :state_changed
      assert event.payload == %{x: 1}
      assert event.parent_id == nil
    end

    test "append/4 sets parent_id when provided" do
      {:ok, sid} = EventLog.start_session()
      {:ok, e1} = EventLog.append(sid, :first, %{})
      {:ok, e2} = EventLog.append(sid, :second, %{}, e1.id)
      assert e2.parent_id == e1.id
    end

    test "increments the session event_count" do
      {:ok, sid} = EventLog.start_session()
      EventLog.append(sid, :a, %{})
      EventLog.append(sid, :b, %{})
      {:ok, sessions} = EventLog.list_sessions()
      session = Enum.find(sessions, &(&1.id == sid))
      assert session.event_count == 2
    end

    test "returns {:error, :session_not_found} for unknown session" do
      assert {:error, :session_not_found} =
               EventLog.append("ses_doesnotexist00", :type, %{})
    end

    test "returns {:error, :session_ended} for a closed session" do
      {:ok, sid} = EventLog.start_session()
      EventLog.end_session(sid)
      assert {:error, :session_ended} = EventLog.append(sid, :type, %{})
    end
  end
end
