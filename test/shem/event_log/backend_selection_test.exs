defmodule Shem.EventLog.BackendSelectionTest do
  use ExUnit.Case, async: false

  # Note: Shem.EventLog is already started as a named process by the supervisor
  # in the test env. We use GenServer.start_link/3 directly to create anonymous
  # instances that exercise init/1 → select_store/0 without conflicting with the
  # running named process.

  test "selects DETSStore when single-node and no :force_mnesia" do
    Application.delete_env(:shem, :force_mnesia)
    Application.delete_env(:shem, :event_log_store)
    # Single-node: Node.list() == [] in test env
    {:ok, pid} = GenServer.start_link(Shem.EventLog, [], [])
    state = :sys.get_state(pid)
    assert state.store == Shem.EventLog.DETSStore
    GenServer.stop(pid)
  after
    Application.delete_env(:shem, :event_log_store)
    Application.delete_env(:shem, :force_mnesia)
  end

  test "selects MnesiaStore when :force_mnesia is true" do
    Application.put_env(:shem, :force_mnesia, true)
    Application.delete_env(:shem, :event_log_store)
    {:ok, pid} = GenServer.start_link(Shem.EventLog, [], [])
    state = :sys.get_state(pid)
    assert state.store == Shem.EventLog.MnesiaStore
    GenServer.stop(pid)
  after
    Application.delete_env(:shem, :force_mnesia)
    Application.put_env(:shem, :event_log_store, Shem.EventLog.FakeStore)
  end

  test "explicit :event_log_store config overrides auto-selection" do
    Application.put_env(:shem, :event_log_store, Shem.EventLog.DETSStore)
    Application.put_env(:shem, :force_mnesia, true)
    {:ok, pid} = GenServer.start_link(Shem.EventLog, [], [])
    state = :sys.get_state(pid)
    assert state.store == Shem.EventLog.DETSStore
    GenServer.stop(pid)
  after
    Application.delete_env(:shem, :event_log_store)
    Application.delete_env(:shem, :force_mnesia)
    Application.put_env(:shem, :event_log_store, Shem.EventLog.FakeStore)
  end
end
