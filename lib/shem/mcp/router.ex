defmodule Shem.MCP.Router do
  use Plug.Router

  alias Shem.MCP.Handlers.{ExecuteCode, GraduateTool, ListTools, InvokeTool}

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["*/*"]
  )

  plug(:match)
  plug(:dispatch)

  get "/sse" do
    session_id = generate_session_id()
    port = Application.get_env(:shem, :mcp_port, 4000)
    endpoint_url = "http://localhost:#{port}/message?sessionId=#{session_id}"

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    Shem.MCP.SessionRegistry.register_sse(session_id, self())

    case chunk(conn, "event: endpoint\ndata: #{endpoint_url}\n\n") do
      {:ok, conn} -> sse_loop(conn, session_id)
      {:error, _} -> unregister(session_id, conn)
    end
  end

  post "/message" do
    session_id = conn.query_params["sessionId"]

    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        send_resp(conn, 400, Jason.encode!(%{"error" => "parse error"}))

      params when is_map(params) ->
        handle_rpc(conn, params, session_id)

      _ ->
        send_resp(conn, 400, Jason.encode!(%{"error" => "parse error"}))
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # ── JSON-RPC dispatch ──────────────────────────────────────────────────────

  defp handle_rpc(conn, params, session_id) do
    id = Map.get(params, "id")
    method = Map.get(params, "method")
    args = Map.get(params, "params", %{})

    if is_nil(id) do
      send_resp(conn, 204, "")
    else
      result = dispatch_method(method, args)
      response = build_response(id, result)
      send_or_sse(conn, session_id, response)
    end
  end

  defp dispatch_method("initialize", _args) do
    {:ok,
     %{
       "protocolVersion" => "2024-11-05",
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => "shem", "version" => "0.1.0"}
     }}
  end

  defp dispatch_method("ping", _args), do: {:ok, %{}}

  defp dispatch_method("tools/list", _args) do
    {:ok, %{"tools" => builtin_tool_descriptors()}}
  end

  defp dispatch_method("tools/call", %{"name" => name, "arguments" => arguments}) do
    case call_tool(name, arguments) do
      {:ok, result} ->
        {:ok, %{"content" => [%{"type" => "text", "text" => inspect(result)}]}}

      {:error, kind, detail} ->
        {:error, -32602, "#{kind}: #{inspect(detail)}"}

      {:error, kind} ->
        {:error, -32602, inspect(kind)}
    end
  end

  defp dispatch_method("tools/call", _), do: {:error, -32602, "missing name or arguments"}
  defp dispatch_method(_, _), do: {:error, -32601, "Method not found"}

  defp call_tool("execute_code", args), do: ExecuteCode.call(args)
  defp call_tool("graduate_tool", args), do: GraduateTool.call(args)
  defp call_tool("list_tools", args), do: ListTools.call(args)
  defp call_tool("invoke_tool", args), do: InvokeTool.call(args)
  defp call_tool(_, _), do: {:error, :not_found}

  defp build_response(id, {:ok, result}),
    do: %{"jsonrpc" => "2.0", "result" => result, "id" => id}

  defp build_response(id, {:error, code, message}),
    do: %{"jsonrpc" => "2.0", "error" => %{"code" => code, "message" => message}, "id" => id}

  # ── SSE helpers ────────────────────────────────────────────────────────────

  defp send_or_sse(conn, nil, response) do
    send_resp(conn, 200, Jason.encode!(response))
  end

  defp send_or_sse(conn, session_id, response) do
    Shem.MCP.SessionRegistry.send_to_session(session_id, response)
    send_resp(conn, 202, "")
  end

  defp sse_loop(conn, session_id) do
    receive do
      {:mcp_response, data} ->
        payload = "data: #{Jason.encode!(data)}\n\n"

        case chunk(conn, payload) do
          {:ok, conn} -> sse_loop(conn, session_id)
          {:error, _} -> unregister(session_id, conn)
        end

      :close ->
        unregister(session_id, conn)
    after
      30_000 ->
        case chunk(conn, ": ping\n\n") do
          {:ok, conn} -> sse_loop(conn, session_id)
          {:error, _} -> unregister(session_id, conn)
        end
    end
  end

  defp unregister(session_id, conn) do
    Shem.MCP.SessionRegistry.unregister_session(session_id)
    conn
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  # ── Built-in tool descriptors ──────────────────────────────────────────────

  defp builtin_tool_descriptors do
    [
      %{
        "name" => "execute_code",
        "description" =>
          "Compile and run Elixir source in a scratch context. Source must define a module with run/0. Nothing persists.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "source" => %{"type" => "string", "description" => "Elixir source code"}
          },
          "required" => ["source"]
        }
      },
      %{
        "name" => "graduate_tool",
        "description" =>
          "Atomically compile, test, and register a tool. Fails with details if tests fail.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "source" => %{"type" => "string", "description" => "Tool implementation source"},
            "test_source" => %{
              "type" => "string",
              "description" => "Test module source defining run/0"
            },
            "input_schema" => %{
              "type" => "object",
              "description" => "JSON Schema for the tool's run/1 args (optional)"
            }
          },
          "required" => ["source", "test_source"]
        }
      },
      %{
        "name" => "list_tools",
        "description" => "List all graduated tools in the registry.",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "invoke_tool",
        "description" => "Invoke a graduated tool by id, passing args to its run/1 function.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => "Tool id from list_tools"},
            "args" => %{
              "type" => "object",
              "description" => "Arguments matching the tool's input_schema"
            }
          },
          "required" => ["id"]
        }
      }
    ]
  end
end
