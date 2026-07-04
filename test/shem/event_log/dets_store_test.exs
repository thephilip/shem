defmodule Shem.EventLog.DETSStoreTest do
  use ExUnit.Case, async: false

  alias Shem.EventLog.{DETSStore, Event}

  setup do
    dir = Path.join(System.tmp_dir!(), "shem_dets_#{:erlang.unique_integer([:positive])}")
    session_id = "ses_#{:erlang.unique_integer([:positive])}"
    {:ok, handle} = DETSStore.open(session_id, dir)

    on_exit(fn ->
      DETSStore.close(handle)
      File.rm_rf!(dir)
    end)

    %{handle: handle, dir: dir, session_id: session_id}
  end

  test "open/2 creates the directory if it does not exist" do
    dir = Path.join(System.tmp_dir!(), "shem_new_#{:erlang.unique_integer([:positive])}")
    refute File.exists?(dir)
    {:ok, handle} = DETSStore.open("ses_new", dir)
    assert File.exists?(dir)
    DETSStore.close(handle)
    File.rm_rf!(dir)
  end

  test "open/2 creates a .dets file in the given directory", %{dir: dir, session_id: sid} do
    assert File.exists?(Path.join(dir, "#{sid}.dets"))
  end

  test "append/2 stores an event and read_all/1 returns it", %{handle: handle} do
    event = Event.new("ses_test", :state_changed, %{x: 1})
    assert :ok = DETSStore.append(handle, event)
    assert {:ok, [^event]} = DETSStore.read_all(handle)
  end

  test "read_all/1 returns multiple events sorted by timestamp", %{handle: handle} do
    e1 = Event.new("ses_test", :first, %{})
    Process.sleep(2)
    e2 = Event.new("ses_test", :second, %{})
    DETSStore.append(handle, e2)
    DETSStore.append(handle, e1)
    {:ok, events} = DETSStore.read_all(handle)
    assert Enum.map(events, & &1.type) == [:first, :second]
  end

  test "read_all/1 orders by :seq (append order) when timestamps tie", %{handle: handle} do
    # Same timestamp (events firing in one microsecond), appended out of order.
    # Without :seq ordering these come back non-deterministically and break the
    # hash chain; with it they read back in append order regardless.
    ts = ~U[2026-06-28 12:00:00.000000Z]
    e2 = %{Event.new("ses_test", :c, %{}) | timestamp: ts, seq: 2}
    e0 = %{Event.new("ses_test", :a, %{}) | timestamp: ts, seq: 0}
    e1 = %{Event.new("ses_test", :b, %{}) | timestamp: ts, seq: 1}
    for e <- [e2, e0, e1], do: :ok = DETSStore.append(handle, e)

    assert {:ok, events} = DETSStore.read_all(handle)
    assert Enum.map(events, & &1.seq) == [0, 1, 2]
    assert Enum.map(events, & &1.type) == [:a, :b, :c]
  end

  test "get/2 retrieves an event by id", %{handle: handle} do
    event = Event.new("ses_test", :tool_invoked, %{tool: "bash"})
    DETSStore.append(handle, event)
    assert {:ok, ^event} = DETSStore.get(handle, event.id)
  end

  test "get/2 returns :not_found for an unknown id", %{handle: handle} do
    assert {:error, :not_found} = DETSStore.get(handle, "evt_0000000000000000")
  end

  describe "gc digest + prune" do
    test "put_digest/get_digest round-trips and is invisible to read_all", %{handle: handle} do
      digest = %{covers_to_seq: 4, count: 5, beam_anchor: "AB", portable_anchor: "cd", pruned_at: DateTime.utc_now()}
      assert :ok = DETSStore.put_digest(handle, digest)
      assert {:ok, ^digest} = DETSStore.get_digest(handle)
      {:ok, events} = DETSStore.read_all(handle)
      assert Enum.all?(events, &match?(%Shem.EventLog.Event{}, &1))
    end

    test "get_digest with no digest", %{handle: handle} do
      assert {:error, :none} = DETSStore.get_digest(handle)
    end

    test "prune deletes rows up to seq, keeps the rest and the digest", %{handle: handle} do
      events =
        for i <- 0..9 do
          e = %{Shem.EventLog.Event.new("ses_X", :test, %{i: i}) | seq: i, hash: "H#{i}"}
          :ok = DETSStore.append(handle, e)
          e
        end

      :ok = DETSStore.put_digest(handle, %{covers_to_seq: 4, count: 5, beam_anchor: "H4", portable_anchor: "p", pruned_at: DateTime.utc_now()})
      assert :ok = DETSStore.prune(handle, 4)
      {:ok, remaining} = DETSStore.read_all(handle)
      assert Enum.map(remaining, & &1.seq) == [5, 6, 7, 8, 9]
      assert {:ok, _} = DETSStore.get_digest(handle)
      assert {:error, :not_found} = DETSStore.get(handle, Enum.at(events, 0).id)
    end
  end
end
