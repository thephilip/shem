defmodule Shem.MCP.RecallToolsTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Shem.MCP.Router
  alias Shem.EventLog.Event

  @opts Router.init([])

  setup do
    path = "tmp/test_recall_mcp_#{:erlang.unique_integer([:positive])}"
    File.mkdir_p!(path)
    orig = Application.get_env(:shem, :event_log_path, "tmp/test_events")
    Application.put_env(:shem, :event_log_path, path)
    # reset the singleton index so it re-scans our temp dir
    :ok = Supervisor.terminate_child(Shem.Supervisor, Shem.Recall.Index)
    {:ok, _} = Supervisor.restart_child(Shem.Supervisor, Shem.Recall.Index)

    on_exit(fn ->
      Application.put_env(:shem, :event_log_path, orig)
      Supervisor.terminate_child(Shem.Supervisor, Shem.Recall.Index)
      Supervisor.restart_child(Shem.Supervisor, Shem.Recall.Index)
      File.rm_rf!(path)
    end)

    %{path: path}
  end

  defp write_session(session_id, events, path) do
    dets_file = Path.join(path, "#{session_id}.dets") |> String.to_charlist()
    table = :"recall_mcp_#{session_id}_#{:erlang.unique_integer([:positive])}"
    {:ok, tab} = :dets.open_file(table, file: dets_file, type: :set)
    for event <- events, do: :dets.insert(tab, {event.id, event})
    :dets.close(tab)
  end

  defp call_tool(name, arguments) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments},
        "id" => 1
      })

    conn =
      conn(:post, "/message", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    [%{"type" => "text", "text" => text}] = resp["result"]["content"]
    Jason.decode!(text)
  end

  test "tools/list includes recall_search and recall_context" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "tools/list", "params" => %{}, "id" => 1})

    conn =
      conn(:post, "/message", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    names = Jason.decode!(conn.resp_body)["result"]["tools"] |> Enum.map(& &1["name"])
    assert "recall_search" in names
    assert "recall_context" in names
  end

  test "recall_search over MCP returns shaped hits", %{path: path} do
    sid = "ses_MCP_RC"
    write_session(sid, [
      Event.new(sid, :agent_started, %{task: "profile the mnesia checkpoint latency"}),
      Event.new(sid, :llm_call_completed, %{content: "measuring now"})
    ], path)

    result = call_tool("recall_search", %{"query" => "mnesia checkpoint"})
    assert result["status"] == "ok"
    assert [hit | _] = result["hits"]
    assert hit["session_id"] == sid
    assert hit["fork"]["endpoint"] == "POST /api/sessions/#{sid}/fork"
  end

  test "recall_context over MCP returns the window", %{path: path} do
    sid = "ses_MCP_CTX"
    e1 = Event.new(sid, :agent_started, %{task: "ctx target"})
    e2 = Event.new(sid, :agent_done, %{content: "done"})
    write_session(sid, [e1, e2], path)

    result = call_tool("recall_context", %{"session_id" => sid, "event_id" => e1.id, "radius" => 5})
    assert Enum.map(result["events"], & &1["event_id"]) == [e1.id, e2.id]
  end

  test "recall_search without a query is an invalid-args error" do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "recall_search", "arguments" => %{}},
        "id" => 1
      })

    conn =
      conn(:post, "/message", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert %{"error" => %{"code" => -32602}} = Jason.decode!(conn.resp_body)
  end
end
