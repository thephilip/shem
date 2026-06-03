defmodule Shem.EventLog.SessionTest do
  use ExUnit.Case, async: true

  alias Shem.EventLog.Session

  test "new/0 creates a session with generated id, started_at, zero event_count" do
    session = Session.new()
    assert String.starts_with?(session.id, "ses_")
    assert byte_size(session.id) == 20
    assert %DateTime{} = session.started_at
    assert session.ended_at == nil
    assert session.event_count == 0
  end

  test "generate_id/0 returns unique ids across 100 calls" do
    ids = for _ <- 1..100, do: Session.generate_id()
    assert length(Enum.uniq(ids)) == 100
  end

  test "increment/1 increases event_count by 1 each call" do
    s = Session.new()
    assert Session.increment(s).event_count == 1
    assert s |> Session.increment() |> Session.increment() |> Map.get(:event_count) == 2
  end

  test "close/1 sets ended_at to a DateTime" do
    session = Session.new()
    closed = Session.close(session)
    assert %DateTime{} = closed.ended_at
  end
end
