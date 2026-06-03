defmodule Shem.EventLog.ReplayTest do
  use ExUnit.Case, async: true

  alias Shem.EventLog.{Replay, Event}

  defp make_event(id, type, parent_id \\ nil) do
    %Event{
      id: id,
      session_id: "ses_test00000000",
      parent_id: parent_id,
      type: type,
      payload: %{},
      timestamp: DateTime.utc_now()
    }
  end

  describe "fold/3" do
    test "reduces events with the given reducer" do
      events = [make_event("evt_1", :a), make_event("evt_2", :b), make_event("evt_3", :c)]
      reducer = fn count, _e -> count + 1 end
      assert Replay.fold(events, 0, reducer) == 3
    end

    test "returns initial state for an empty list" do
      assert Replay.fold([], :initial, fn s, _ -> s end) == :initial
    end

    test "passes each event to the reducer in order" do
      events = [make_event("evt_1", :x), make_event("evt_2", :y)]
      reducer = fn acc, event -> acc ++ [event.type] end
      assert Replay.fold(events, [], reducer) == [:x, :y]
    end
  end

  describe "state_at/4" do
    test "folds up to and including the target event" do
      events = [
        make_event("evt_1", :a),
        make_event("evt_2", :b),
        make_event("evt_3", :c)
      ]
      reducer = fn acc, e -> acc ++ [e.type] end
      assert {:ok, [:a, :b]} = Replay.state_at(events, "evt_2", [], reducer)
    end

    test "includes the target event in the fold" do
      events = [make_event("evt_1", :only)]
      reducer = fn acc, e -> acc ++ [e.type] end
      assert {:ok, [:only]} = Replay.state_at(events, "evt_1", [], reducer)
    end

    test "returns {:error, :event_not_found} for unknown event_id" do
      events = [make_event("evt_1", :a)]
      assert {:error, :event_not_found} =
               Replay.state_at(events, "evt_missing0000000", [], fn s, _ -> s end)
    end

    test "does not fold events after the target" do
      events = [
        make_event("evt_1", :a),
        make_event("evt_2", :b),
        make_event("evt_3", :c)
      ]
      reducer = fn acc, e -> acc ++ [e.type] end
      {:ok, result} = Replay.state_at(events, "evt_1", [], reducer)
      refute :b in result
      refute :c in result
    end
  end

  describe "causal_chain/2" do
    test "returns events from root to target in causal order" do
      events = [
        make_event("evt_1", :root, nil),
        make_event("evt_2", :child, "evt_1"),
        make_event("evt_3", :grandchild, "evt_2"),
        make_event("evt_4", :unrelated, nil)
      ]
      chain = Replay.causal_chain(events, "evt_3")
      assert Enum.map(chain, & &1.id) == ["evt_1", "evt_2", "evt_3"]
    end

    test "returns just the event when parent_id is nil" do
      events = [make_event("evt_1", :root, nil)]
      assert [%Event{id: "evt_1"}] = Replay.causal_chain(events, "evt_1")
    end

    test "returns empty list for an event_id not in the list" do
      events = [make_event("evt_1", :root, nil)]
      assert [] = Replay.causal_chain(events, "evt_missing0000000")
    end

    test "excludes unrelated events from the chain" do
      events = [
        make_event("evt_1", :root, nil),
        make_event("evt_2", :child, "evt_1"),
        make_event("evt_3", :sibling, "evt_1")
      ]
      chain = Replay.causal_chain(events, "evt_2")
      ids = Enum.map(chain, & &1.id)
      assert "evt_3" not in ids
    end
  end
end
