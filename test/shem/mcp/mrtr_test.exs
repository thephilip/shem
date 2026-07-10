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
end
