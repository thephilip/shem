defmodule Shem.EventLog.ChainTest do
  use ExUnit.Case, async: true

  alias Shem.EventLog.{Chain, Event}

  @sid "ses_CHAIN_TEST"

  defp event(type, payload) do
    Event.new(@sid, type, payload)
  end

  defp chained(events) do
    {hashed, _} =
      Enum.map_reduce(events, Chain.genesis(@sid), fn e, prev ->
        h = Chain.next(prev, e)
        {%{e | hash: h}, h}
      end)

    hashed
  end

  test "genesis is deterministic per session" do
    assert Chain.genesis(@sid) == Chain.genesis(@sid)
    refute Chain.genesis(@sid) == Chain.genesis("ses_OTHER")
  end

  test "a correctly chained list verifies" do
    events = chained([event(:a, %{x: 1}), event(:b, %{x: 2}), event(:c, %{x: 3})])
    assert {:ok, :verified, 3} = Chain.verify(events, @sid)
  end

  test "an all-nil-hash list is legacy" do
    events = [event(:a, %{x: 1}), event(:b, %{x: 2})]
    assert {:ok, :legacy, 2} = Chain.verify(events, @sid)
  end

  test "empty list is legacy with zero events" do
    assert {:ok, :legacy, 0} = Chain.verify([], @sid)
  end

  test "a tampered payload is detected at the exact event" do
    [e1, e2, e3] = chained([event(:a, %{x: 1}), event(:b, %{x: 2}), event(:c, %{x: 3})])
    tampered = %{e2 | payload: %{x: 666}}
    assert {:error, {:broken_at, broken_id}} = Chain.verify([e1, tampered, e3], @sid)
    assert broken_id == e2.id
  end

  test "a relinked chain (recomputed after tamper) breaks at the next event" do
    [e1, e2, e3] = chained([event(:a, %{x: 1}), event(:b, %{x: 2}), event(:c, %{x: 3})])
    # attacker rewrites e2's payload AND recomputes e2's hash — but e3's
    # stored hash no longer chains from the forged e2 hash
    forged_payload = %{x: 666}
    forged_e2 = %{e2 | payload: forged_payload, hash: Chain.next(e1.hash, %{e2 | payload: forged_payload})}
    assert {:error, {:broken_at, broken_id}} = Chain.verify([e1, forged_e2, e3], @sid)
    assert broken_id == e3.id
  end

  test "legacy prefix followed by a hashed segment verifies from genesis" do
    legacy = [event(:old1, %{x: 0}), event(:old2, %{x: 0})]
    hashed = chained([event(:new1, %{x: 1}), event(:new2, %{x: 2})])
    assert {:ok, :verified, 4} = Chain.verify(legacy ++ hashed, @sid)
  end

  test "a nil hash after a hashed event is broken" do
    [e1, e2] = chained([event(:a, %{x: 1}), event(:b, %{x: 2})])
    gap = Shem.EventLog.Event.new(@sid, :c, %{x: 3})
    assert {:error, {:broken_at, broken_id}} = Chain.verify([e1, e2, gap], @sid)
    assert broken_id == gap.id
  end

  test "a rewritten parent_id (causal link) is detected" do
    [e1, e2] = chained([event(:a, %{x: 1}), event(:b, %{x: 2})])
    relinked = %{e2 | parent_id: "evt_FORGED"}
    assert {:error, {:broken_at, broken_id}} = Chain.verify([e1, relinked], @sid)
    assert broken_id == e2.id
  end

  # NOTE: the cross-process chain-stability fix (`:deterministic` in
  # Chain.canonical) is not unit-testable here — the bug is a >32-key HAMT whose
  # term_to_binary order depends on the per-VM-boot map seed, so it only diverges
  # ACROSS OS processes; within one test VM equal maps always share internal
  # order. Validated by cross-process live replay (see the Phase 3 SDD ledger).

  defp chained(session_id, n) do
    {events, _} =
      Enum.map_reduce(0..(n - 1), Chain.genesis(session_id), fn i, prev ->
        e = %{Event.new(session_id, :test, %{i: i}) | seq: i}
        e = %{e | hash: Chain.next(prev, e)}
        {e, e.hash}
      end)
    events
  end

  describe "verify/3 with digest" do
    test "verifies tail seeded at beam_anchor and reports pruned/replayable" do
      sid = "ses_GC1"
      events = chained(sid, 10)
      {pruned, kept} = Enum.split(events, 6)
      digest = %{covers_to_seq: 5, count: 6, beam_anchor: List.last(pruned).hash,
                 portable_anchor: "p", pruned_at: DateTime.utc_now()}
      assert {:ok, :verified_gc, %{pruned: 6, replayable: 4}} = Chain.verify(kept, sid, digest)
    end

    test "drops already-covered rows (crash between digest write and delete)" do
      sid = "ses_GC2"
      events = chained(sid, 10)
      digest = %{covers_to_seq: 5, count: 6, beam_anchor: Enum.at(events, 5).hash,
                 portable_anchor: "p", pruned_at: DateTime.utc_now()}
      # full list still present — verify must skip seq <= 5 and still pass
      assert {:ok, :verified_gc, %{pruned: 6, replayable: 4}} = Chain.verify(events, sid, digest)
    end

    test "tampered tail is caught" do
      sid = "ses_GC3"
      events = chained(sid, 10)
      {pruned, kept} = Enum.split(events, 6)
      digest = %{covers_to_seq: 5, count: 6, beam_anchor: List.last(pruned).hash,
                 portable_anchor: "p", pruned_at: DateTime.utc_now()}
      [first | rest] = kept
      tampered = [%{first | payload: %{i: 666}} | rest]
      assert {:error, {:broken_at, _}} = Chain.verify(tampered, sid, digest)
    end

    test "nil beam_anchor degrades to legacy" do
      sid = "ses_GC4"
      kept = chained(sid, 4)
      digest = %{covers_to_seq: -1, count: 3, beam_anchor: nil,
                 portable_anchor: "p", pruned_at: DateTime.utc_now()}
      assert {:ok, :legacy, %{pruned: 3, replayable: 4}} = Chain.verify(kept, sid, digest)
    end

    test "nil digest is exactly the old behavior" do
      sid = "ses_GC5"
      events = chained(sid, 3)
      assert {:ok, :verified, 3} = Chain.verify(events, sid, nil)
    end
  end
end
