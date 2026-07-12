defmodule Shem.RecallTest do
  use ExUnit.Case, async: false

  alias Shem.Recall
  alias Shem.Recall.Scanner
  alias Shem.EventLog.Event

  setup do
    path = "tmp/test_recall_#{:erlang.unique_integer([:positive])}"
    File.mkdir_p!(path)
    orig = Application.get_env(:shem, :event_log_path, "tmp/test_events")
    Application.put_env(:shem, :event_log_path, path)
    idx = start_supervised!({Shem.Recall.Index, name: :"recall_#{:erlang.unique_integer([:positive])}"})

    on_exit(fn ->
      Application.put_env(:shem, :event_log_path, orig)
      File.rm_rf!(path)
    end)

    %{path: path, index: idx}
  end

  defp write_session(session_id, events, path) do
    dets_file = Path.join(path, "#{session_id}.dets") |> String.to_charlist()
    table = :"recall_t_#{session_id}_#{:erlang.unique_integer([:positive])}"
    {:ok, tab} = :dets.open_file(table, file: dets_file, type: :set)
    for event <- events, do: :dets.insert(tab, {event.id, event})
    :dets.close(tab)
  end

  defp seed_session(path) do
    sid = "ses_RECALL_SEED"
    e1 = Event.new(sid, :agent_started, %{task: "investigate the flaky websocket reconnect"})
    e2 = Event.new(sid, :llm_call_completed, %{content: "I will read the reconnect code"})
    e3 = Event.new(sid, :tool_call, %{tool: "read_file", args: %{path: "ws.ex"}})
    e4 = Event.new(sid, :agent_done, %{content: "reconnect fixed with backoff"})
    write_session(sid, [e1, e2, e3, e4], path)
    {sid, [e1, e2, e3, e4]}
  end

  test "search returns shaped hits with fork pointer", %{path: path, index: idx} do
    {sid, [_e1, e2, e3, _e4]} = seed_session(path)

    {:ok, %{status: "ok", hits: hits}} = Recall.search("websocket reconnect", 5, index: idx)
    hit = Enum.find(hits, &(&1.session_id == sid))
    assert hit.event_type in ["agent_started", "llm_call_completed", "agent_done"]
    assert hit.snippet =~ "reconnect"
    assert hit.fork.endpoint == "POST /api/sessions/#{sid}/fork"

    # the tool_call event's nearest preceding llm_call_completed is e2
    {:ok, ctx} = Recall.context(sid, e3.id, 1, index: idx)
    assert ctx.fork.fork_event_id == e2.id
  end

  test "search distinguishes empty corpus from no matches", %{path: path, index: idx} do
    {:ok, %{status: "no_sessions_indexed", hits: []}} = Recall.search("anything", 5, index: idx)

    write_session("ses_RECALL_NM", [Event.new("ses_RECALL_NM", :agent_started, %{task: "alpha"})], path)
    {:ok, %{status: "no_matches", hits: []}} = Recall.search("zzzunfindable", 5, index: idx)
  end

  test "every search appends a :recall_query event to the query session", %{path: path, index: idx} do
    write_session("ses_RECALL_Q", [Event.new("ses_RECALL_Q", :agent_started, %{task: "beta"})], path)

    {:ok, _} = Recall.search("beta", 5, index: idx)

    {:ok, events} = Shem.EventLog.read_session_events(Scanner.query_session_id())
    assert [%Event{type: :recall_query, payload: p} | _] = Enum.reverse(events)
    assert p.query == "beta"
    assert is_integer(p.hit_count)
  end

  test "redacted payloads never surface in hits or context", %{path: path, index: idx} do
    sid = "ses_RECALL_RED"
    # what append-time redaction stores: the marker, never the plaintext
    e = Event.new(sid, :tool_call, %{result: %{"$redacted" => "abc123def4567890"}, note: "secretive run"})
    write_session(sid, [e], path)

    {:ok, %{hits: hits}} = Recall.search("secretive", 5, index: idx)
    assert [hit] = hits
    refute hit.snippet =~ "hunter2"

    {:ok, ctx} = Recall.context(sid, e.id, 3, index: idx)
    assert inspect(ctx.events) =~ "$redacted"
  end

  test "context returns the window around the event", %{path: path, index: idx} do
    {sid, [e1, e2, e3, e4]} = seed_session(path)

    {:ok, ctx} = Recall.context(sid, e2.id, 1, index: idx)
    assert Enum.map(ctx.events, & &1.event_id) == [e1.id, e2.id, e3.id]

    {:ok, ctx_all} = Recall.context(sid, e2.id, 10, index: idx)
    assert length(ctx_all.events) == 4
    assert List.last(ctx_all.events).event_id == e4.id
  end

  test "context errors on unknown session or event", %{index: idx} do
    assert {:error, :session_not_found} = Recall.context("ses_NOPE", "evt_x", 3, index: idx)
  end
end
