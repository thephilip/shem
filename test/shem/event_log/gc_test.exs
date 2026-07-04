defmodule Shem.EventLog.GCTest do
  use ExUnit.Case, async: false

  alias Shem.EventLog

  defp seed(n) do
    {:ok, sid} = EventLog.start_session()
    for i <- 0..(n - 1), do: {:ok, _} = EventLog.append(sid, :test, %{i: i})
    sid
  end

  # Reaches into the FakeStore ETS table backing an active session to insert
  # an event straight (bypassing EventLog.append), to forge a legacy (nil-seq)
  # row. There is no public accessor for the handle, so we go through
  # :sys.get_state/1 on the named EventLog process.
  defp store_append(sid, event) do
    state = :sys.get_state(Shem.EventLog)
    {handle, _session} = Map.fetch!(state.sessions, sid)
    :ets.insert(handle, {event.id, event})
    :ok
  end

  test "gc prunes to keep, verify_chain reports verified_gc" do
    sid = seed(20)
    assert {:ok, %{pruned: 15, total_pruned: 15, kept: 5}} = EventLog.gc(sid, 5)
    {:ok, events} = EventLog.events(sid)
    assert length(events) == 5
    assert {:ok, :verified_gc, %{pruned: 15, replayable: 5}} = EventLog.verify_chain(sid)
    assert {:ok, %{count: 15, covers_to_seq: 14}} = EventLog.get_digest(sid)
  end

  test "gc coalesces across passes" do
    sid = seed(20)
    {:ok, _} = EventLog.gc(sid, 10)
    for i <- 20..29, do: {:ok, _} = EventLog.append(sid, :test, %{i: i})
    assert {:ok, %{pruned: 15, total_pruned: 25, kept: 5}} = EventLog.gc(sid, 5)
    assert {:ok, :verified_gc, %{pruned: 25, replayable: 5}} = EventLog.verify_chain(sid)
  end

  test "gc after a crash-window digest (leftover covered rows) does not double-fold" do
    sid = seed(30)
    state = :sys.get_state(Shem.EventLog)
    {handle, _session} = Map.fetch!(state.sessions, sid)
    {:ok, events} = EventLog.events(sid)

    # Simulate the crash window: a digest covering seq 0..24 is durable, but
    # the matching prune never ran — all 30 rows are still in the store, same
    # as if the process died between store.put_digest and store.prune in do_gc.
    {leaked, _kept} = Enum.split(events, 25)
    last = List.last(leaked)

    portable =
      Enum.reduce(leaked, Shem.Attest.portable_genesis(sid), fn e, acc ->
        Shem.Attest.portable_next(acc, Shem.Attest.CanonicalJSON.encode(Shem.Attest.event_view(e)))
      end)

    crash_digest = %{
      covers_to_seq: last.seq,
      count: length(leaked),
      beam_anchor: last.hash,
      portable_anchor: portable,
      pruned_at: DateTime.utc_now()
    }

    :ok = state.store.put_digest(handle, crash_digest)

    # A correct implementation only folds the truly-new tail (seq 25..27) on
    # top of the existing anchor. The buggy version re-reads all 30 raw rows,
    # re-splits on `keep`, and folds rows 0..27 (including the 25 already
    # covered by crash_digest) onto an anchor that already covers them.
    expected_new_pruned = Enum.filter(events, &(&1.seq > crash_digest.covers_to_seq and &1.seq <= 27))
    expected_portable =
      Enum.reduce(expected_new_pruned, crash_digest.portable_anchor, fn e, acc ->
        Shem.Attest.portable_next(acc, Shem.Attest.CanonicalJSON.encode(Shem.Attest.event_view(e)))
      end)

    assert {:ok, %{pruned: 3, total_pruned: 28, kept: 2}} = EventLog.gc(sid, 2)
    assert {:ok, %{count: 28, covers_to_seq: 27, portable_anchor: ^expected_portable}} =
             EventLog.get_digest(sid)
    assert {:ok, :verified_gc, %{pruned: 28, replayable: 2}} = EventLog.verify_chain(sid)
  end

  test "gc below keep is a noop" do
    sid = seed(3)
    assert {:ok, :noop} = EventLog.gc(sid, 5)
    assert {:ok, :verified, 3} = EventLog.verify_chain(sid)
  end

  test "keep clamps to 1" do
    sid = seed(5)
    assert {:ok, %{kept: 1}} = EventLog.gc(sid, 0)
  end

  test "appends after gc continue the chain and still verify" do
    sid = seed(10)
    {:ok, _} = EventLog.gc(sid, 3)
    for i <- 10..14, do: {:ok, _} = EventLog.append(sid, :test, %{i: i})
    assert {:ok, :verified_gc, %{pruned: 7, replayable: 8}} = EventLog.verify_chain(sid)
  end

  describe "resumed GC'd session (DETS)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "shem_gc_dets_#{:erlang.unique_integer([:positive])}")
      Application.put_env(:shem, :event_log_store, Shem.EventLog.DETSStore)
      Application.put_env(:shem, :event_log_path, dir)

      on_exit(fn ->
        Application.put_env(:shem, :event_log_store, Shem.EventLog.FakeStore)
        Application.delete_env(:shem, :event_log_path)
        Supervisor.terminate_child(Shem.Supervisor, Shem.EventLog)
        Supervisor.restart_child(Shem.Supervisor, Shem.EventLog)
        File.rm_rf!(dir)
      end)

      :ok
    end

    test "resumed GC'd session continues seq past the pruned range" do
      GenServer.stop(Shem.EventLog)
      wait_until_registered()

      sid = seed(10)
      {:ok, _} = EventLog.gc(sid, 3)
      :ok = EventLog.end_session(sid)

      GenServer.stop(Shem.EventLog)
      wait_until_registered()

      {:ok, ^sid} = EventLog.start_session(sid)
      {:ok, e} = EventLog.append(sid, :test, %{i: 10})
      # length(stored) after gc keep=3 is 3 → old code would mint seq=3
      assert e.seq == 10
      assert {:ok, :verified_gc, _} = EventLog.verify_chain(sid)
    end

    test "get_digest falls back to the historical DETS file when the active store misses" do
      # Controlled restart (terminate_child/restart_child), not GenServer.stop —
      # a raw stop is an unplanned exit the supervisor counts against its
      # restart intensity, and this describe block's other test already spends
      # some of that budget.
      Supervisor.terminate_child(Shem.Supervisor, Shem.EventLog)
      Supervisor.restart_child(Shem.Supervisor, Shem.EventLog)

      sid = seed(10)
      {:ok, _} = EventLog.gc(sid, 3)
      :ok = EventLog.end_session(sid)

      # Simulate the node's active store no longer being the one this session's
      # digest lives under (e.g. MnesiaStore in a cluster, DETS from a historical
      # single-node run). FakeStore's ETS-table read_all raises on a bare string
      # handle, so store_has_session? for it returns false — this pins the
      # "session not in active state, store read misses → DETS fallback" branch
      # of get_digest, not a real cross-store cluster scenario.
      Application.put_env(:shem, :event_log_store, Shem.EventLog.FakeStore)
      Supervisor.terminate_child(Shem.Supervisor, Shem.EventLog)
      Supervisor.restart_child(Shem.Supervisor, Shem.EventLog)

      # No start_session — sessions map is empty, forcing the non-active path
      # for both read_session_events (existing DETS fallback) and get_digest
      # (this fix). Without the fix, get_digest returns {:error, :none} and
      # verify_chain walks from genesis, reporting a false chain break.
      assert {:ok, :verified_gc, %{pruned: 7, replayable: 3}} = EventLog.verify_chain(sid)
    end
  end

  test "legacy session (nil seq) is refused" do
    sid = seed(3)
    {:ok, events} = EventLog.events(sid)
    legacy = %{List.first(events) | id: "evt_LEGACY", seq: nil, hash: nil}
    store_append(sid, legacy)
    assert {:error, :legacy_session} = EventLog.gc(sid, 1)
  end

  test "unknown session" do
    assert {:error, :not_found} = EventLog.gc("ses_NOPE", 5)
  end

  defmodule Widget do
    defstruct [:name]
  end

  test "gc and verify_chain succeed when a payload embeds structs (DateTime, custom struct)" do
    {:ok, sid} = EventLog.start_session()
    for i <- 0..8, do: {:ok, _} = EventLog.append(sid, :test, %{i: i})

    {:ok, _} =
      EventLog.append(sid, :test, %{
        at: DateTime.utc_now(),
        widget: %Widget{name: "gizmo"}
      })

    for i <- 10..14, do: {:ok, _} = EventLog.append(sid, :test, %{i: i})

    assert {:ok, %{kept: 5}} = EventLog.gc(sid, 5)
    assert {:ok, :verified_gc, _} = EventLog.verify_chain(sid)
  end

  defp wait_until_registered(attempts \\ 100)

  defp wait_until_registered(0), do: flunk("Shem.EventLog did not re-register")

  defp wait_until_registered(attempts) do
    if Process.whereis(Shem.EventLog) do
      :ok
    else
      Process.sleep(10)
      wait_until_registered(attempts - 1)
    end
  end

  test "pruned ids are :pruned, not :not_found" do
    sid = seed(10)
    {:ok, [first | _]} = EventLog.events(sid)
    {:ok, _} = EventLog.gc(sid, 3)
    assert {:error, :pruned} = EventLog.event(sid, first.id)
    assert {:error, :pruned} = EventLog.reconstruct_at(sid, first.id, fn s, _ -> s end, nil)
    assert {:error, :pruned} = EventLog.scrub(sid, first.id)
    # unknown id on a GC'd session also reads :pruned (id could have been pruned — honest ambiguity)
    assert {:error, :pruned} = EventLog.event(sid, "evt_NOPE")
    # unknown id on an un-GC'd session stays :not_found
    sid2 = seed(3)
    assert {:error, :not_found} = EventLog.event(sid2, "evt_NOPE")
  end

  describe "auto-GC" do
    setup do
      prev = Application.get_env(:shem, :gc)
      Application.put_env(:shem, :gc, keep_events: 10)
      on_exit(fn -> Application.put_env(:shem, :gc, prev || [keep_events: :infinity]) end)
    end

    test "fires past 2x keep_events, prunes to keep_events" do
      sid = seed(21)   # 21st append crosses 2*10
      {:ok, events} = EventLog.events(sid)
      assert length(events) == 10
      assert {:ok, %{count: 11}} = EventLog.get_digest(sid)
      assert {:ok, :verified_gc, _} = EventLog.verify_chain(sid)
      # hysteresis: 5 more appends stay under 2x — no second pass
      for i <- 21..25, do: {:ok, _} = EventLog.append(sid, :test, %{i: i})
      {:ok, events} = EventLog.events(sid)
      assert length(events) == 15
      assert {:ok, %{count: 11}} = EventLog.get_digest(sid)
    end

    test ":infinity disables" do
      Application.put_env(:shem, :gc, keep_events: :infinity)
      sid = seed(30)
      {:ok, events} = EventLog.events(sid)
      assert length(events) == 30
    end

    test "keep_events: 0 clamps to 1 inside do_gc — auto-GC bypasses the public gc/2 clamp" do
      Application.put_env(:shem, :gc, keep_events: 0)
      sid = seed(5)
      {:ok, events} = EventLog.events(sid)
      assert length(events) >= 1
      assert {:ok, :verified_gc, _} = EventLog.verify_chain(sid)
    end
  end
end
