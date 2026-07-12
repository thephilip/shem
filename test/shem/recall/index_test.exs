defmodule Shem.Recall.IndexTest do
  use ExUnit.Case, async: false

  alias Shem.Recall.{Index, Scanner}
  alias Shem.EventLog.Event

  setup do
    path = "tmp/test_recall_idx_#{:erlang.unique_integer([:positive])}"
    File.mkdir_p!(path)
    orig = Application.get_env(:shem, :event_log_path, "tmp/test_events")
    Application.put_env(:shem, :event_log_path, path)
    # fresh index per test — the app-supervised one may hold other tests' state
    idx = start_supervised!({Index, name: :"recall_idx_#{:erlang.unique_integer([:positive])}"})

    on_exit(fn ->
      Application.put_env(:shem, :event_log_path, orig)
      File.rm_rf!(path)
    end)

    %{path: path, index: idx}
  end

  defp write_session(session_id, events, path) do
    dets_file = Path.join(path, "#{session_id}.dets") |> String.to_charlist()
    table = :"recall_idx_#{session_id}_#{:erlang.unique_integer([:positive])}"
    {:ok, tab} = :dets.open_file(table, file: dets_file, type: :set)
    for event <- events, do: :dets.insert(tab, {event.id, event})
    :dets.close(tab)
  end

  test "search finds the session whose events match the query", %{path: path, index: idx} do
    write_session("ses_IDX_HIT", [
      Event.new("ses_IDX_HIT", :agent_started, %{task: "debug the segfault in the tokenizer"}),
      Event.new("ses_IDX_HIT", :agent_done, %{content: "fixed"})
    ], path)

    write_session("ses_IDX_MISS", [
      Event.new("ses_IDX_MISS", :agent_started, %{task: "write a haiku about spring"})
    ], path)

    %{hits: hits, skipped: [], indexed_sessions: 2} = Index.search(idx, "tokenizer segfault", 5)
    assert [%{session_id: "ses_IDX_HIT", event_id: id, score: s} | _] = hits
    assert is_binary(id) and s > 0
    refute Enum.any?(hits, &(&1.session_id == "ses_IDX_MISS"))
  end

  test "re-search picks up a session added after the first query", %{path: path, index: idx} do
    write_session("ses_IDX_ONE", [Event.new("ses_IDX_ONE", :agent_started, %{task: "alpha"})], path)
    %{indexed_sessions: 1} = Index.search(idx, "alpha", 5)

    write_session("ses_IDX_TWO", [Event.new("ses_IDX_TWO", :agent_started, %{task: "bravo"})], path)
    %{hits: hits, indexed_sessions: 2} = Index.search(idx, "bravo", 5)
    assert [%{session_id: "ses_IDX_TWO"}] = hits
  end

  test "search matches on event type name", %{path: path, index: idx} do
    write_session("ses_IDX_TYPE", [Event.new("ses_IDX_TYPE", :hardening_check, %{score: 0.9})], path)

    %{hits: hits} = Index.search(idx, "hardening", 5)
    assert [%{session_id: "ses_IDX_TYPE"}] = hits
  end

  test "limit caps the number of hits", %{path: path, index: idx} do
    for i <- 1..4 do
      sid = "ses_IDX_L#{i}"
      write_session(sid, [Event.new(sid, :agent_started, %{task: "needle number #{i}"})], path)
    end

    %{hits: hits} = Index.search(idx, "needle", 2)
    assert length(hits) == 2
  end

  test "query-log session is not indexed", %{path: path, index: idx} do
    write_session(Scanner.query_session_id(), [
      Event.new(Scanner.query_session_id(), :recall_query, %{query: "zebra"})
    ], path)

    %{hits: [], indexed_sessions: 0} = Index.search(idx, "zebra", 5)
  end

  test "a chain-broken session is skipped and reported, not indexed", %{path: path, index: idx} do
    # NOTE: fixture events need REAL hashes — nil-hash events read as :legacy,
    # which indexes fine. Chain the events, then tamper one (the exact pattern
    # from test/shem/event_log/chain_test.exs).
    alias Shem.EventLog.Chain
    sid = "ses_IDX_BROKEN"
    events = [
      Event.new(sid, :agent_started, %{task: "tamperable run"}),
      Event.new(sid, :agent_done, %{content: "fine"})
    ]

    {[e1, e2], _} =
      Enum.map_reduce(events, Chain.genesis(sid), fn e, prev ->
        h = Chain.next(prev, e)
        {%{e | hash: h}, h}
      end)

    tampered = %{e1 | payload: %{task: "REWRITTEN HISTORY"}}
    write_session(sid, [tampered, e2], path)

    %{hits: hits, skipped: skipped} = Index.search(idx, "rewritten history", 5)
    assert hits == []
    assert [%{session_id: ^sid, reason: reason}] = skipped
    assert reason =~ "broken_chain"
  end
end
