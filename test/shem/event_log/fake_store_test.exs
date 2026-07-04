defmodule Shem.EventLog.FakeStoreTest do
  use ExUnit.Case, async: true

  alias Shem.EventLog.{FakeStore, Event}

  setup do
    {:ok, handle} = FakeStore.open("ses_test", "/ignored/path")
    on_exit(fn -> FakeStore.close(handle) end)
    %{handle: handle}
  end

  test "open/2 returns an ETS table reference", %{handle: handle} do
    assert is_atom(handle)
    assert :ets.info(handle) != :undefined
  end

  test "append/2 stores the event and read_all/1 returns it", %{handle: handle} do
    event = Event.new("ses_test", :state_changed, %{val: 1})
    assert :ok = FakeStore.append(handle, event)
    assert {:ok, [^event]} = FakeStore.read_all(handle)
  end

  test "read_all/1 returns events sorted by timestamp", %{handle: handle} do
    e1 = Event.new("ses_test", :first, %{})
    Process.sleep(2)
    e2 = Event.new("ses_test", :second, %{})
    FakeStore.append(handle, e2)
    FakeStore.append(handle, e1)
    {:ok, events} = FakeStore.read_all(handle)
    assert Enum.map(events, & &1.type) == [:first, :second]
  end

  test "get/2 retrieves a stored event by id", %{handle: handle} do
    event = Event.new("ses_test", :tool_invoked, %{tool: "bash"})
    FakeStore.append(handle, event)
    assert {:ok, ^event} = FakeStore.get(handle, event.id)
  end

  test "get/2 returns :not_found for an unknown id", %{handle: handle} do
    assert {:error, :not_found} = FakeStore.get(handle, "evt_0000000000000000")
  end

  test "close/1 deletes the ETS table", %{handle: handle} do
    assert :ok = FakeStore.close(handle)
    assert :ets.info(handle) == :undefined
  end

  describe "gc digest + prune" do
    test "put_digest/get_digest round-trips and is invisible to read_all", %{handle: handle} do
      digest = %{covers_to_seq: 4, count: 5, beam_anchor: "AB", portable_anchor: "cd", pruned_at: DateTime.utc_now()}
      assert :ok = FakeStore.put_digest(handle, digest)
      assert {:ok, ^digest} = FakeStore.get_digest(handle)
      {:ok, events} = FakeStore.read_all(handle)
      assert Enum.all?(events, &match?(%Shem.EventLog.Event{}, &1))
    end

    test "get_digest with no digest", %{handle: handle} do
      assert {:error, :none} = FakeStore.get_digest(handle)
    end

    test "prune deletes rows up to seq, keeps the rest and the digest", %{handle: handle} do
      events =
        for i <- 0..9 do
          e = %{Shem.EventLog.Event.new("ses_X", :test, %{i: i}) | seq: i, hash: "H#{i}"}
          :ok = FakeStore.append(handle, e)
          e
        end

      :ok = FakeStore.put_digest(handle, %{covers_to_seq: 4, count: 5, beam_anchor: "H4", portable_anchor: "p", pruned_at: DateTime.utc_now()})
      assert :ok = FakeStore.prune(handle, 4)
      {:ok, remaining} = FakeStore.read_all(handle)
      assert Enum.map(remaining, & &1.seq) == [5, 6, 7, 8, 9]
      assert {:ok, _} = FakeStore.get_digest(handle)
      assert {:error, :not_found} = FakeStore.get(handle, Enum.at(events, 0).id)
    end
  end
end
