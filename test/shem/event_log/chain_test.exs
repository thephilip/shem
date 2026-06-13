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
end
