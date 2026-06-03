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
end
