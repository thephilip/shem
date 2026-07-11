defmodule Shem.REST.SessionsTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Shem.REST.Router
  alias Shem.EventLog

  @opts Router.init([])

  defp get_path(path) do
    conn(:get, path) |> Router.call(@opts)
  end

  defp post_json(path, body) do
    encoded = Jason.encode!(body)
    conn(:post, path, encoded)
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  # GET /sessions ──────────────────────────────────────────────────────────────

  test "GET /sessions returns a list" do
    conn = get_path("/sessions")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_list(body)
  end

  test "GET /sessions includes an active session as active: true with status running" do
    {:ok, session_id} = EventLog.start_session()
    EventLog.append(session_id, :agent_started, %{task: "test task", preset: "general"})

    conn = get_path("/sessions")
    assert conn.status == 200
    sessions = Jason.decode!(conn.resp_body)

    found = Enum.find(sessions, &(&1["session_id"] == session_id))
    assert found != nil
    assert found["active"] == true
    assert found["status"] == "running"
    assert found["task"] == "test task"

    EventLog.end_session(session_id)
  end

  test "GET /sessions reports awaiting_turn for a parked client-brain agent's session" do
    {:ok, name, sid} =
      Shem.Agent.start_with_preset("general", "parked status test", brain: :client)

    wait_for_awaiting(sid)

    conn = get_path("/sessions")
    assert conn.status == 200
    found = Jason.decode!(conn.resp_body) |> Enum.find(&(&1["session_id"] == sid))

    assert found != nil
    assert found["active"] == true
    assert found["status"] == "awaiting_turn"

    Shem.Agent.stop(name)
  end

  defp wait_for_awaiting(sid, n \\ 250)
  defp wait_for_awaiting(_sid, 0), do: flunk("agent never parked")

  defp wait_for_awaiting(sid, n) do
    case Shem.MCP.Handlers.AgentCommon.find_by_session(sid) do
      {:ok, name} ->
        case Shem.Agent.info(name) do
          {:ok, %{status: :awaiting_turn}} ->
            name

          _ ->
            Process.sleep(20)
            wait_for_awaiting(sid, n - 1)
        end

      :not_found ->
        Process.sleep(20)
        wait_for_awaiting(sid, n - 1)
    end
  end

  test "GET /sessions session entries have required fields" do
    {:ok, session_id} = EventLog.start_session()
    EventLog.append(session_id, :agent_started, %{task: "field check", preset: "coder"})

    conn = get_path("/sessions")
    sessions = Jason.decode!(conn.resp_body)
    found = Enum.find(sessions, &(&1["session_id"] == session_id))

    assert Map.has_key?(found, "session_id")
    assert Map.has_key?(found, "task")
    assert Map.has_key?(found, "started_at")
    assert Map.has_key?(found, "status")
    assert Map.has_key?(found, "turn_count")
    assert Map.has_key?(found, "active")

    EventLog.end_session(session_id)
  end

  # GET /sessions/:id/events ───────────────────────────────────────────────────

  test "GET /sessions/:id/events returns 404 for unknown session" do
    conn = get_path("/sessions/nonexistent_session_id_xyz/events")
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "session not found"
  end

  test "GET /sessions/:id/events returns event list for a known session" do
    {:ok, session_id} = EventLog.start_session()
    EventLog.append(session_id, :agent_started, %{task: "events test", preset: "general"})
    EventLog.append(session_id, :llm_call_completed, %{content: "hello", tokens_used: 10, latency_ms: 500, model: "test"})

    conn = get_path("/sessions/#{session_id}/events")
    assert conn.status == 200
    events = Jason.decode!(conn.resp_body)

    assert is_list(events)
    assert length(events) == 2

    first = hd(events)
    assert first["type"] == "agent_started"
    assert Map.has_key?(first, "id")
    assert Map.has_key?(first, "timestamp")
    assert Map.has_key?(first, "payload")

    EventLog.end_session(session_id)
  end

  test "GET /sessions/:id/events events are in chronological order" do
    {:ok, session_id} = EventLog.start_session()
    EventLog.append(session_id, :agent_started, %{task: "order test"})
    EventLog.append(session_id, :agent_turn_completed, %{turn: 1})
    EventLog.append(session_id, :agent_done, %{content: "done"})

    conn = get_path("/sessions/#{session_id}/events")
    assert conn.status == 200
    events = Jason.decode!(conn.resp_body)

    types = Enum.map(events, & &1["type"])
    assert types == ["agent_started", "agent_turn_completed", "agent_done"]

    EventLog.end_session(session_id)
  end

  # POST /sessions/:id/fork ────────────────────────────────────────────────────

  test "POST /sessions/:id/fork returns 404 for unknown session" do
    conn = post_json("/sessions/nonexistent_xyz/fork", %{fork_event_id: "evt_000"})
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "session not found"
  end

  test "POST /sessions/:id/fork returns 400 when fork_event_id is missing" do
    {:ok, session_id} = EventLog.start_session()
    EventLog.append(session_id, :agent_started, %{task: "fork test"})

    conn = post_json("/sessions/#{session_id}/fork", %{})
    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "fork_event_id is required"

    EventLog.end_session(session_id)
  end

  test "POST /sessions/:id/fork returns 422 when fork_event_id not in session" do
    {:ok, session_id} = EventLog.start_session()
    EventLog.append(session_id, :agent_started, %{task: "fork test"})

    conn = post_json("/sessions/#{session_id}/fork", %{fork_event_id: "evt_DOESNOTEXIST"})
    assert conn.status == 422
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "fork_event_id not found in session"

    EventLog.end_session(session_id)
  end

  test "POST /sessions/:id/fork returns 422 when event is not llm_call_completed" do
    {:ok, session_id} = EventLog.start_session()
    {:ok, event} = EventLog.append(session_id, :agent_started, %{task: "fork test"})

    conn = post_json("/sessions/#{session_id}/fork", %{fork_event_id: event.id})
    assert conn.status == 422
    body = Jason.decode!(conn.resp_body)
    assert body["error"] =~ "llm_call_completed"

    EventLog.end_session(session_id)
  end

  test "POST /sessions/:id/fork creates new session with events up to fork point" do
    {:ok, session_id} = EventLog.start_session()
    {:ok, _} = EventLog.append(session_id, :agent_started, %{task: "fork test"})
    {:ok, llm_event} = EventLog.append(session_id, :llm_call_completed, %{content: "original", tokens_used: 5, latency_ms: 100, model: "test"})
    {:ok, _} = EventLog.append(session_id, :agent_done, %{content: "done"})

    conn = post_json("/sessions/#{session_id}/fork", %{fork_event_id: llm_event.id})
    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["session_id"])
    new_session_id = body["session_id"]

    # Forked session: a branch_created provenance marker, then events up to and
    # including the llm_call_completed (but not agent_done past the fork point).
    {:ok, forked_events} = EventLog.read_session_events(new_session_id)
    assert length(forked_events) == 3
    types = Enum.map(forked_events, & &1.type)
    assert types == [:branch_created, :agent_started, :llm_call_completed]
    assert :agent_done not in types

    branch = hd(forked_events)
    assert branch.payload[:original_session_id] == session_id
    assert branch.payload[:fork_event_id] == llm_event.id

    EventLog.end_session(session_id)
    EventLog.end_session(new_session_id)
  end

  test "POST /sessions/:id/fork injects alt_response into the forked llm_call_completed event" do
    {:ok, session_id} = EventLog.start_session()
    {:ok, _} = EventLog.append(session_id, :agent_started, %{task: "fork override test"})
    {:ok, llm_event} = EventLog.append(session_id, :llm_call_completed, %{content: "original response", tokens_used: 5, latency_ms: 100, model: "test"})

    conn = post_json("/sessions/#{session_id}/fork", %{
      fork_event_id: llm_event.id,
      alt_response: "overridden response"
    })
    assert conn.status == 201
    new_session_id = Jason.decode!(conn.resp_body)["session_id"]

    {:ok, forked_events} = EventLog.read_session_events(new_session_id)
    assert length(forked_events) == 3
    last = List.last(forked_events)
    assert last.type == :llm_call_completed
    assert last.payload[:content] == "overridden response"

    EventLog.end_session(session_id)
    EventLog.end_session(new_session_id)
  end

  test "POST /sessions/:id/fork without alt_response preserves original content" do
    {:ok, session_id} = EventLog.start_session()
    {:ok, _} = EventLog.append(session_id, :agent_started, %{task: "fork identical test"})
    {:ok, llm_event} = EventLog.append(session_id, :llm_call_completed, %{content: "keep this", tokens_used: 5, latency_ms: 100, model: "test"})

    conn = post_json("/sessions/#{session_id}/fork", %{fork_event_id: llm_event.id})
    assert conn.status == 201
    new_session_id = Jason.decode!(conn.resp_body)["session_id"]

    {:ok, forked_events} = EventLog.read_session_events(new_session_id)
    assert length(forked_events) == 3
    last = List.last(forked_events)
    assert last.payload[:content] == "keep this"

    EventLog.end_session(session_id)
    EventLog.end_session(new_session_id)
  end

  test "POST /sessions/:id/fork with continue:true builds an unfinalized fork and resumes a client-brain agent" do
    {:ok, session_id} = EventLog.start_session()
    {:ok, _} = EventLog.append(session_id, :agent_started, %{task: "continue test"})
    {:ok, _} = EventLog.append(session_id, :agent_checkpoint, %{history: [%{role: :user, content: "continue test"}], turn_count: 0, config: %{}, node: node()})
    {:ok, llm_event} = EventLog.append(session_id, :llm_call_completed, %{content: "original", tokens_used: 0, latency_ms: 1, model: "test"})

    conn = post_json("/sessions/#{session_id}/fork", %{fork_event_id: llm_event.id, alt_response: "DIVERGED", continue: true})
    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert body["continued"] == true
    assert is_binary(body["agent_id"])
    new_session_id = body["session_id"]

    # The fork is NOT finalized: the resumed agent reconstructed state and appended.
    {:ok, forked_events} = EventLog.read_session_events(new_session_id)
    assert Enum.any?(forked_events, &(&1.type == :agent_resumed))

    EventLog.end_session(session_id)
  end

  # GET /sessions/:id/verify ───────────────────────────────────────────────────

  describe "GET /:id/verify" do
    test "verified session" do
      {:ok, sid} = Shem.EventLog.start_session()
      {:ok, _} = Shem.EventLog.append(sid, :x, %{n: 1})

      conn = get_path("/sessions/#{sid}/verify")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["verified"] == true
      assert body["events"] == 1
    end

    test "unknown session is 404" do
      conn = get_path("/sessions/ses_NO_SUCH/verify")
      assert conn.status == 404
    end

    test "GC'd session reports pruned and replayable" do
      {:ok, sid} = Shem.EventLog.start_session()
      {:ok, _} = Shem.EventLog.append(sid, :x, %{n: 1})
      {:ok, _} = Shem.EventLog.append(sid, :x, %{n: 2})
      {:ok, _} = Shem.EventLog.append(sid, :x, %{n: 3})

      # GC with keep=2 should prune the first event, leaving 2 replayable
      {:ok, _} = Shem.EventLog.gc(sid, 2)

      conn = get_path("/sessions/#{sid}/verify")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["verified"] == true
      assert body["events"] == 2
      assert is_integer(body["pruned"])
      assert body["pruned"] == 1
    end
  end
end
