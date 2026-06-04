defmodule Shem.MCP.RouterTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Shem.MCP.Router

  @opts Router.init([])

  defp post_rpc(method, params, id \\ 1) do
    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id})

    conn(:post, "/message", body)
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp decode_response(conn) do
    Jason.decode!(conn.resp_body)
  end

  test "POST /message initialize returns server info" do
    conn =
      post_rpc("initialize", %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "0.0.1"}
      })

    assert conn.status == 200
    resp = decode_response(conn)
    assert resp["result"]["serverInfo"]["name"] == "shem"
    assert resp["id"] == 1
  end

  test "POST /message tools/list returns the four Shem tools" do
    conn = post_rpc("tools/list", %{})
    assert conn.status == 200
    resp = decode_response(conn)
    names = Enum.map(resp["result"]["tools"], & &1["name"])
    assert "execute_code" in names
    assert "graduate_tool" in names
    assert "list_tools" in names
    assert "invoke_tool" in names
  end

  test "POST /message tools/call execute_code returns result" do
    source = """
    defmodule RouterExecTest1 do
      def run(), do: "hello from exec"
    end
    """

    conn =
      post_rpc("tools/call", %{"name" => "execute_code", "arguments" => %{"source" => source}})

    assert conn.status == 200
    resp = decode_response(conn)
    assert [%{"type" => "text", "text" => text}] = resp["result"]["content"]
    assert text =~ "hello from exec"
  end

  test "POST /message unknown method returns method-not-found error" do
    conn = post_rpc("unknown/method", %{})
    assert conn.status == 200
    resp = decode_response(conn)
    assert resp["error"]["code"] == -32601
  end

  test "POST /message notification (no id) returns 204 no content" do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized",
        "params" => %{}
      })

    conn =
      conn(:post, "/message", body)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 204
  end
end
