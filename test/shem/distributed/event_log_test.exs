defmodule Shem.Distributed.EventLogTest do
  use ExUnit.Case, async: false

  @moduletag :distributed

  # Run with:
  #   elixir --sname shem_test -S mix test --only distributed

  alias Shem.EventLog.{MnesiaStore, Event}

  setup_all do
    unless Node.alive?() do
      Node.start(:shem_test, :shortnames)
    end

    :ok
  end

  # ── Helpers (same pattern as cluster_test.exs) ───────────────────────────────

  defp start_peer(short_name) do
    build_path = Mix.Project.build_path()
    elixir_lib = :code.lib_dir(:elixir) |> Path.dirname() |> to_string()

    pa_args =
      (Path.wildcard(Path.join([elixir_lib, "*", "ebin"])) ++
         Path.wildcard(Path.join([build_path, "lib", "*", "ebin"])))
      |> Enum.flat_map(fn p -> [~c"-pa", String.to_charlist(p)] end)

    {:ok, peer, node} =
      :peer.start(%{
        name: short_name,
        args: pa_args
      })

    :rpc.call(node, :application, :ensure_all_started, [:elixir])
    :rpc.call(node, :application, :ensure_all_started, [:mnesia])
    {:ok, peer, node}
  end

  defp assert_eventually(fun, timeout_ms, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if fun.() do
        :ok
      else
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(interval_ms)
          :retry
        else
          :timeout
        end
      end
    end)
    |> Enum.find(fn r -> r in [:ok, :timeout] end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("Condition not met within #{timeout_ms}ms")
    end
  end

  defp setup_mnesia_on_peer(peer_node) do
    self_node = Node.self()

    :rpc.call(peer_node, Code, :eval_string, [
      """
      Application.ensure_all_started(:mnesia)
      :mnesia.change_config(:extra_db_nodes, [:"#{self_node}"])
      case :mnesia.add_table_copy(:shem_events, node(), :disc_copies) do
        {:atomic, :ok} -> :ok
        {:aborted, {:already_exists, :shem_events, _}} -> :ok
      end
      :mnesia.wait_for_tables([:shem_events], 10_000)
      """
    ])
  end

  # ── Tests ────────────────────────────────────────────────────────────────────

  test "write events on node A — read from node B" do
    {:ok, peer, peer_node} = start_peer(:shem_b_el39a)
    on_exit(fn -> :peer.stop(peer) end)

    setup_mnesia_on_peer(peer_node)

    session_id = "ses_dist_#{:erlang.unique_integer([:positive])}"
    {:ok, handle} = MnesiaStore.open(session_id, "/ignored")
    event = Event.new(session_id, :agent_started, %{name: "alice"})
    :ok = MnesiaStore.append(handle, event)

    assert_eventually(
      fn ->
        result =
          :rpc.call(peer_node, Code, :eval_string, [
            """
            alias Shem.EventLog.MnesiaStore
            case MnesiaStore.read_all("#{session_id}") do
              {:ok, events} -> length(events)
              _ -> 0
            end
            """
          ])

        case result do
          {count, _} when is_integer(count) -> count == 1
          _ -> false
        end
      end,
      5_000
    )
  end

  test "node A dies mid-session — node B reads session from Mnesia" do
    {:ok, peer, peer_node} = start_peer(:shem_b_el39b)

    session_id = "ses_dead_#{:erlang.unique_integer([:positive])}"
    {:ok, handle} = MnesiaStore.open(session_id, "/ignored")

    e1 = Event.new(session_id, :turn_started, %{turn: 1})
    e2 = Event.new(session_id, :turn_started, %{turn: 2})
    :ok = MnesiaStore.append(handle, e1)
    :ok = MnesiaStore.append(handle, e2)

    setup_mnesia_on_peer(peer_node)

    # Wait for replication to peer before stopping it
    assert_eventually(
      fn ->
        result =
          :rpc.call(peer_node, Code, :eval_string, [
            """
            alias Shem.EventLog.MnesiaStore
            case MnesiaStore.read_all("#{session_id}") do
              {:ok, events} -> length(events)
              _ -> 0
            end
            """
          ])

        case result do
          {2, _} -> true
          _ -> false
        end
      end,
      5_000
    )

    # Stop peer — simulating "node A dies"
    :peer.stop(peer)

    # Our local node still has the events in its own Mnesia copy
    {:ok, events} = MnesiaStore.read_all(session_id)
    assert length(events) == 2
    assert Enum.map(events, & &1.payload.turn) == [1, 2]
  end

  test "new node joining live cluster replicates existing events" do
    session_id = "ses_existing_#{:erlang.unique_integer([:positive])}"
    {:ok, handle} = MnesiaStore.open(session_id, "/ignored")

    # Write 5 events before peer joins
    for i <- 1..5 do
      MnesiaStore.append(handle, Event.new(session_id, :step, %{i: i}))
    end

    # Now start peer and onboard it — it should replicate all 5 pre-existing events
    {:ok, peer, peer_node} = start_peer(:shem_b_el39c)
    on_exit(fn -> :peer.stop(peer) end)

    setup_mnesia_on_peer(peer_node)

    assert_eventually(
      fn ->
        result =
          :rpc.call(peer_node, Code, :eval_string, [
            """
            alias Shem.EventLog.MnesiaStore
            case MnesiaStore.read_all("#{session_id}") do
              {:ok, events} -> length(events)
              _ -> 0
            end
            """
          ])

        case result do
          {5, _} -> true
          _ -> false
        end
      end,
      10_000
    )
  end

  test "single-node: EventLog auto-selects DETSStore" do
    # Verify that without Node.list() and without :force_mnesia,
    # EventLog init selects DETSStore (no peers connected in this test).
    Application.delete_env(:shem, :force_mnesia)
    Application.delete_env(:shem, :event_log_store)

    assert Node.list() == [], "Expected no peer nodes for this test — run before the other distributed tests or in isolation"

    {:ok, pid} = GenServer.start_link(Shem.EventLog, [], [])
    state = :sys.get_state(pid)
    assert state.store == Shem.EventLog.DETSStore
    GenServer.stop(pid)
  after
    Application.put_env(:shem, :event_log_store, Shem.EventLog.FakeStore)
  end
end
