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

  describe "events/1" do
    test "returns all appended events in timestamp order" do
      {:ok, sid} = EventLog.start_session()
      {:ok, e1} = EventLog.append(sid, :first, %{})
      {:ok, e2} = EventLog.append(sid, :second, %{})
      {:ok, events} = EventLog.events(sid)
      assert Enum.map(events, & &1.id) == [e1.id, e2.id]
    end

    test "returns {:error, :session_not_found} for unknown session" do
      assert {:error, :session_not_found} = EventLog.events("ses_doesnotexist00")
    end
  end

  describe "event/2" do
    test "retrieves a specific event by id" do
      {:ok, sid} = EventLog.start_session()
      {:ok, e} = EventLog.append(sid, :state_changed, %{val: 42})
      assert {:ok, ^e} = EventLog.event(sid, e.id)
    end

    test "returns {:error, :not_found} for unknown event_id" do
      {:ok, sid} = EventLog.start_session()
      assert {:error, :not_found} = EventLog.event(sid, "evt_0000000000000000")
    end
  end

  describe "reconstruct/3" do
    test "folds all events to produce final state" do
      {:ok, sid} = EventLog.start_session()
      EventLog.append(sid, :inc, %{})
      EventLog.append(sid, :inc, %{})
      EventLog.append(sid, :inc, %{})
      reducer = fn count, _event -> count + 1 end
      assert {:ok, 3} = EventLog.reconstruct(sid, reducer, 0)
    end

    test "returns {:ok, initial} for a session with no events" do
      {:ok, sid} = EventLog.start_session()
      assert {:ok, :empty} = EventLog.reconstruct(sid, fn s, _ -> s end, :empty)
    end
  end

  describe "reconstruct_at/4" do
    test "folds only up to and including the given event_id" do
      {:ok, sid} = EventLog.start_session()
      {:ok, e1} = EventLog.append(sid, :inc, %{})
      {:ok, e2} = EventLog.append(sid, :inc, %{})
      {:ok, _e3} = EventLog.append(sid, :inc, %{})
      reducer = fn count, _event -> count + 1 end
      assert {:ok, 2} = EventLog.reconstruct_at(sid, e2.id, reducer, 0)
    end

    test "returns {:error, :event_not_found} for unknown event_id" do
      {:ok, sid} = EventLog.start_session()
      EventLog.append(sid, :inc, %{})
      assert {:error, :event_not_found} =
               EventLog.reconstruct_at(sid, "evt_0000000000000000", fn s, _ -> s end, 0)
    end
  end

  describe "read_session_events/1" do
    test "returns events for an active session" do
      {:ok, sid} = EventLog.start_session()
      {:ok, _} = EventLog.append(sid, :agent_started, %{task: "active task"})
      assert {:ok, events} = EventLog.read_session_events(sid)
      assert length(events) == 1
      assert hd(events).type == :agent_started
    end

    test "returns {:error, :not_found} for an unknown session with no dets file" do
      assert {:error, :not_found} = EventLog.read_session_events("ses_TOTALLY_UNKNOWN_XYZ")
    end
  end

  describe "start_session/1 (external id)" do
    test "opens a session with the provided id" do
      id = "ses_AABBCCDD11223344"
      assert {:ok, ^id} = EventLog.start_session(id)
      {:ok, sessions} = EventLog.list_sessions()
      assert Enum.any?(sessions, &(&1.id == id))
    end

    test "calling start_session/1 twice with same id returns ok without duplicating" do
      id = "ses_DUPLICATE00000001"
      assert {:ok, ^id} = EventLog.start_session(id)
      assert {:ok, ^id} = EventLog.start_session(id)
      {:ok, sessions} = EventLog.list_sessions()
      assert Enum.count(sessions, &(&1.id == id)) == 1
    end

    test "events appended after start_session/1 are retrievable" do
      id = "ses_EXTERNAL00000001"
      {:ok, ^id} = EventLog.start_session(id)
      {:ok, _} = EventLog.append(id, :test_event, %{val: 42})
      assert {:ok, events} = EventLog.events(id)
      assert length(events) == 1
      assert hd(events).type == :test_event
    end
  end
end
