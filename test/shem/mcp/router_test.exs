defmodule Shem.MCP.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

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

  defp call_tool_rpc(name, arguments) do
    conn = post_rpc("tools/call", %{"name" => name, "arguments" => arguments})
    assert conn.status == 200
    resp = decode_response(conn)
    [%{"type" => "text", "text" => text}] = resp["result"]["content"]
    Jason.decode!(text)
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

  describe "agent tools over MCP" do
    setup do
      Shem.LLM.BudgetServer.reset()
      Shem.LLM.StubTransport.Server.reset()
      :ok
    end

    test "tools/list includes the four agent tools" do
      conn = post_rpc("tools/list", %{})
      names = Enum.map(decode_response(conn)["result"]["tools"], & &1["name"])

      for tool <- ["spawn_agent", "agent_status", "list_agents", "stop_agent"] do
        assert tool in names
      end
    end

    test "spawn → poll → stop round-trip over JSON-RPC" do
      Shem.LLM.StubTransport.Server.push_response(
        {:ok,
         %Shem.LLM.Response{content: "rpc answer", tokens_used: 5, model: :default, latency_ms: 1}}
      )

      %{"agent_id" => agent_id, "status" => "running"} =
        call_tool_rpc("spawn_agent", %{"goal" => "round trip"})

      # poll until done (StubTransport answers immediately; allow a few ticks)
      status =
        Enum.reduce_while(1..50, nil, fn _, _ ->
          case call_tool_rpc("agent_status", %{"agent_id" => agent_id}) do
            %{"status" => "done"} = result -> {:halt, result}
            _ ->
              Process.sleep(50)
              {:cont, nil}
          end
        end)

      assert %{"output" => "rpc answer"} = status

      listed = call_tool_rpc("list_agents", %{})
      assert Enum.any?(listed["agents"], &(&1["agent_id"] == agent_id))

      assert %{"ok" => true} = call_tool_rpc("stop_agent", %{"agent_id" => agent_id})
    end

    test "a raising handler returns a JSON-RPC error, not a crash" do
      # agent_status with a non-string id passes JSON decoding but would crash
      # without the dispatch-level rescue if a handler ever raises; simulate via
      # a tools/call to a handler with deliberately type-violating args
      conn = post_rpc("tools/call", %{"name" => "spawn_agent", "arguments" => %{"goal" => 123}})
      resp = decode_response(conn)
      assert resp["error"]["code"] == -32602
    end
  end
end
