defmodule Shem.MCP.MRTRTest do
  use ExUnit.Case, async: false
  import Plug.Test
  alias Shem.MCP.{Router, SessionRegistry}

  @opts Router.init([])
  @mrtr_version "2026-07-28"

  setup do
    start_supervised!(Shem.MCP.SessionRegistry)
    :ok
  end

  # POST /mcp/message with a sessionId; the response arrives on this test
  # process via SessionRegistry (the SSE delivery path), not the HTTP conn.
  defp rpc(sid, body) do
    conn = conn(:post, "/message?sessionId=#{sid}", Jason.encode!(body))
    conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")
    Router.call(conn, @opts)
    assert_receive {:mcp_response, resp}, 5_000
    resp
  end

  defp start_session(capabilities, version \\ @mrtr_version) do
    sid = "mrtr-test-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = SessionRegistry.register_sse(sid, self())

    resp =
      rpc(sid, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => version, "capabilities" => capabilities}
      })

    {sid, resp}
  end

  test "initialize negotiation: elicitation + MRTR version marks the session and echoes the version" do
    {sid, resp} = start_session(%{"elicitation" => %{}})
    assert resp["result"]["protocolVersion"] == @mrtr_version
    assert SessionRegistry.mrtr?(sid)
  end

  test "initialize negotiation: no elicitation capability → legacy version, not MRTR" do
    {sid, resp} = start_session(%{})
    assert resp["result"]["protocolVersion"] == "2024-11-05"
    refute SessionRegistry.mrtr?(sid)
  end

  test "initialize negotiation: elicitation but a legacy version → not MRTR" do
    {sid, resp} = start_session(%{"elicitation" => %{}}, "2025-06-18")
    assert resp["result"]["protocolVersion"] == "2024-11-05"
    refute SessionRegistry.mrtr?(sid)
  end

  defp tool_call(sid, id, extra \\ %{}) do
    params =
      Map.merge(
        %{"name" => "spawn_agent", "arguments" => %{"goal" => "say hi", "brain" => "client"}},
        extra
      )

    rpc(sid, %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => params})
  end

  test "full MRTR round-trip: spawn → elicitation inputRequest → accept → final result" do
    {sid, _} = start_session(%{"elicitation" => %{}})

    resp = tool_call(sid, 2)
    result = resp["result"]
    assert result["resultType"] == "input_required"

    assert %{"turn" => %{"method" => "elicitation/create", "params" => elicit}} =
             result["inputRequests"]

    assert is_binary(elicit["message"]) and elicit["message"] != ""
    assert elicit["requestedSchema"]["required"] == ["content"]
    state = result["requestState"]
    assert is_binary(state)

    # retry the SAME request with the response + echoed requestState (new id per spec)
    resp2 =
      tool_call(sid, 3, %{
        "requestState" => state,
        "inputResponses" => %{
          "turn" => %{"action" => "accept", "content" => %{"content" => "hi there"}}
        }
      })

    assert resp2["error"] == nil
    text = hd(resp2["result"]["content"])["text"]
    assert Jason.decode!(text)["status"] in ["done", "awaiting_turn", "waiting"]
  end

  test "tampered requestState is rejected with a JSON-RPC error" do
    {sid, _} = start_session(%{"elicitation" => %{}})
    resp = tool_call(sid, 2)
    state = resp["result"]["requestState"]

    resp2 =
      tool_call(sid, 3, %{
        "requestState" => state <> "x",
        "inputResponses" => %{
          "turn" => %{"action" => "accept", "content" => %{"content" => "hi"}}
        }
      })

    assert resp2["error"]["code"] == -32602
    assert resp2["result"] == nil
  end

  test "capability gate: non-MRTR session gets today's non-blocking spawn result" do
    {sid, _} = start_session(%{})
    resp = tool_call(sid, 2)
    assert resp["result"]["resultType"] == nil
    decoded = Jason.decode!(hd(resp["result"]["content"])["text"])
    assert decoded["status"] == "running"
    assert is_binary(decoded["agent_id"])
  end

  test "declined elicitation leaves the agent parked and points at the poll loop" do
    {sid, _} = start_session(%{"elicitation" => %{}})
    resp = tool_call(sid, 2)
    state = resp["result"]["requestState"]

    resp2 =
      tool_call(sid, 3, %{
        "requestState" => state,
        "inputResponses" => %{"turn" => %{"action" => "decline"}}
      })

    decoded = Jason.decode!(hd(resp2["result"]["content"])["text"])
    assert decoded["status"] == "awaiting_turn"

    # the agent is still parked and still steerable via the classic loop
    {:ok, st} = Shem.MCP.Handlers.AgentStatus.call(%{"agent_id" => decoded["agent_id"]})
    assert st["status"] == "awaiting_turn"
  end

  test "missing inputResponses on retry re-issues the same inputRequest (spec: ask again, not error)" do
    {sid, _} = start_session(%{"elicitation" => %{}})
    resp = tool_call(sid, 2)
    state = resp["result"]["requestState"]

    resp2 = tool_call(sid, 3, %{"requestState" => state})
    assert resp2["result"]["resultType"] == "input_required"
    assert %{"turn" => _} = resp2["result"]["inputRequests"]
  end
end
