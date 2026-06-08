defmodule Shem.HTTP.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Shem.HTTP.Router

  @opts Router.init([])

  test "GET /api/presets is forwarded to the REST router" do
    conn = conn(:get, "/api/presets") |> Router.call(@opts)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    body = Jason.decode!(conn.resp_body)
    assert is_list(body)
  end

  test "POST /mcp/message with a JSON-RPC notification (no id) returns 204" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}})
    conn =
      conn(:post, "/mcp/message", body)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)
    assert conn.status == 204
  end

  test "GET /unknown-path-xyz returns 404" do
    conn = conn(:get, "/unknown-path-xyz") |> Router.call(@opts)
    assert conn.status == 404
  end

  test "GET / returns 200 with text/html" do
    conn = conn(:get, "/") |> Router.call(@opts)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
  end
end
