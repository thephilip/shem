defmodule Shem.EventLog.EventTest do
  use ExUnit.Case, async: true

  alias Shem.EventLog.Event

  test "new/3 creates an event with generated id, timestamp, and nil parent_id" do
    event = Event.new("ses_abc123", :state_changed, %{key: "value"})
    assert String.starts_with?(event.id, "evt_")
    assert byte_size(event.id) == 20
    assert event.session_id == "ses_abc123"
    assert event.type == :state_changed
    assert event.payload == %{key: "value"}
    assert event.parent_id == nil
    assert %DateTime{} = event.timestamp
  end

  test "new/4 sets parent_id when provided" do
    event = Event.new("ses_abc123", :tool_invoked, %{}, "evt_parent00000000")
    assert event.parent_id == "evt_parent00000000"
  end

  test "generate_id/0 returns unique ids across 100 calls" do
    ids = for _ <- 1..100, do: Event.generate_id()
    assert length(Enum.uniq(ids)) == 100
  end

  test "generate_id/0 returns ids prefixed with 'evt_'" do
    assert String.starts_with?(Event.generate_id(), "evt_")
  end
end
