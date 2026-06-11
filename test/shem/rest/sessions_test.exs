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
end
