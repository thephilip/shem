defmodule Shem.EventLog.MnesiaStoreTest do
  use ExUnit.Case, async: false

  alias Shem.EventLog.{MnesiaStore, Event}

  setup_all do
    # Point Mnesia at a temp dir so this test doesn't touch the real schema
    tmp = Path.join(System.tmp_dir!(), "shem_mnesia_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:mnesia, :dir, String.to_charlist(tmp))
    MnesiaStore.setup!()
    on_exit(fn -> File.rm_rf!(tmp) end)
    :ok
  end

  setup do
    session_id = "ses_#{:erlang.unique_integer([:positive])}"
    {:ok, handle} = MnesiaStore.open(session_id, "/ignored")
    %{handle: handle, session_id: session_id}
  end

  test "open/2 returns {:ok, session_id} as the handle", %{handle: handle, session_id: sid} do
    assert handle == sid
  end

  test "close/1 is a no-op and returns :ok", %{handle: handle} do
    assert :ok = MnesiaStore.close(handle)
  end

  test "append/2 stores an event; read_all/1 returns it", %{handle: handle} do
    event = Event.new(handle, :state_changed, %{x: 1})
    assert :ok = MnesiaStore.append(handle, event)
    assert {:ok, [returned]} = MnesiaStore.read_all(handle)
    assert returned.id == event.id
  end

  test "read_all/1 returns events sorted by timestamp", %{handle: handle} do
    e1 = Event.new(handle, :first, %{})
    Process.sleep(2)
    e2 = Event.new(handle, :second, %{})
    MnesiaStore.append(handle, e2)
    MnesiaStore.append(handle, e1)
    {:ok, events} = MnesiaStore.read_all(handle)
    assert Enum.map(events, & &1.type) == [:first, :second]
  end

  test "read_all/1 is scoped to one session", %{handle: handle} do
    other_session = "ses_other_#{:erlang.unique_integer([:positive])}"
    {:ok, other} = MnesiaStore.open(other_session, "/ignored")
    MnesiaStore.append(handle, Event.new(handle, :mine, %{}))
    MnesiaStore.append(other, Event.new(other, :theirs, %{}))
    {:ok, events} = MnesiaStore.read_all(handle)
    assert length(events) == 1
    assert hd(events).type == :mine
  end

  test "get/2 retrieves an event by id", %{handle: handle} do
    event = Event.new(handle, :tool_invoked, %{tool: "bash"})
    MnesiaStore.append(handle, event)
    assert {:ok, returned} = MnesiaStore.get(handle, event.id)
    assert returned.id == event.id
  end

  test "get/2 returns :not_found for an unknown id", %{handle: handle} do
    assert {:error, :not_found} = MnesiaStore.get(handle, "evt_0000000000000000")
  end
end
