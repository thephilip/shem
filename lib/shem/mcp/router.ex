defmodule Shem.MCP.Router do
  use Plug.Router

  alias Shem.MCP.Handlers.{
    AgentStatus,
    ExecuteCode,
    GraduateTool,
    InstallPack,
    InvokeTool,
    ListAgents,
    ListPacks,
    ListTools,
    ProvideTurn,
    SpawnAgent,
    StopAgent,
    UninstallPack
  }

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
    host = Application.get_env(:shem, :mcp_host, "127.0.0.1")
    endpoint_url = "http://#{host}:#{port}/mcp/message?sessionId=#{session_id}"

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
    handle_rpc(conn, conn.body_params, session_id)
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
       "serverInfo" => %{
         "name" => "shem",
         "version" => to_string(Application.spec(:shem, :vsn) || "dev")
       },
       # Surfaced to the client model: tells it WHEN to reach for Shem, not just
       # what each tool does. The "used" lever (see docs/future-work/2026-06-28-llm-usage-stickiness.md).
       "instructions" => server_instructions()
     }}
  end

  defp server_instructions do
    """
    Shem is a BEAM-native server for autonomous, self-evolving agents. Reach for it \
    instead of doing work inline whenever the work should outlive this turn, run \
    concurrently/fault-tolerantly, or be replayable:

    - spawn_agent: delegate a task to an agent that runs concurrently and survives \
    crashes/node death. Use brain: "client" to drive its turns yourself via \
    provide_turn (no separate model needed).
    - write_tool / graduate_tool: when you've written code you'll likely need again, \
    graduate it — it's property-tested, persisted, and callable in EVERY future \
    session, instead of re-deriving it each time.
    - list_tools / invoke_tool: call tools you or earlier sessions already graduated \
    before writing new code.
    - Every run is a forkable, hash-verified event log: fork at any turn to explore \
    "what if it had decided differently", then replay/verify deterministically.

    Prefer doing it inline only for genuine one-offs that don't need to persist, \
    parallelize, or be audited.
    """
  end

  defp dispatch_method("ping", _args), do: {:ok, %{}}

  defp dispatch_method("tools/list", _args) do
    {:ok, %{"tools" => builtin_tool_descriptors()}}
  end

  defp dispatch_method("tools/call", %{"name" => name, "arguments" => arguments}) do
    result =
      try do
        call_tool(name, arguments)
      rescue
        e -> {:error, :handler_crashed, Exception.message(e)}
      catch
        :exit, reason -> {:error, :handler_crashed, inspect(reason)}
      end

    case result do
      {:ok, result} ->
        text =
          case Jason.encode(result) do
            {:ok, json} -> json
            {:error, _} -> inspect(result)
          end

        {:ok, %{"content" => [%{"type" => "text", "text" => text}]}}

      {:error, kind, detail} ->
        {:error, error_code(kind), "#{kind}: #{inspect(detail)}"}

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
  defp call_tool("spawn_agent", args), do: SpawnAgent.call(args)
  defp call_tool("agent_status", args), do: AgentStatus.call(args)
  defp call_tool("list_agents", args), do: ListAgents.call(args)
  defp call_tool("stop_agent", args), do: StopAgent.call(args)
  defp call_tool("provide_turn", args), do: ProvideTurn.call(args)
  defp call_tool("install_pack", args), do: InstallPack.call(args)
  defp call_tool("uninstall_pack", args), do: UninstallPack.call(args)
  defp call_tool("list_packs", args), do: ListPacks.call(args)
  defp call_tool(_, _), do: {:error, :not_found}

  defp build_response(id, {:ok, result}),
    do: %{"jsonrpc" => "2.0", "result" => result, "id" => id}

  defp build_response(id, {:error, code, message}),
    do: %{"jsonrpc" => "2.0", "error" => %{"code" => code, "message" => message}, "id" => id}

  # JSON-RPC 2.0: -32602 invalid params, -32603 internal error
  defp error_code(kind) when kind in [:spawn_failed, :handler_crashed], do: -32603
  defp error_code(_kind), do: -32602

  # ── SSE helpers ────────────────────────────────────────────────────────────

  defp send_or_sse(conn, nil, response) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
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
          "Atomically compile, test, and register a tool. Fails with details if tests fail. Include at least one StreamData property (StreamData.check_all) in test_source — tools without property tests graduate at reduced trust (:medium).",
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
      },
      %{
        "name" => "spawn_agent",
        "description" =>
          "Start a Shem agent with a goal. Returns an agent_id immediately (non-blocking). Poll with agent_status.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "goal" => %{"type" => "string", "description" => "The task for the agent"},
            "preset" => %{
              "type" => "string",
              "description" =>
                "Agent preset (general, coder, researcher, writer, security, explorer). Default: general"
            },
            "brain" => %{
              "type" => "string",
              "description" =>
                "Brain mode: 'client' to drive turns from MCP (use provide_turn), 'model' for autonomous LLM-driven loop (default)"
            }
          },
          "required" => ["goal"]
        }
      },
      %{
        "name" => "agent_status",
        "description" =>
          "Poll a Shem agent by id. Returns status (running|waiting|awaiting_turn|paused|done|error), accumulated output, and event count. When status is done or error, output holds the final result. When status is awaiting_turn (client-brained agents), the response also includes prompt and turn_token for use with provide_turn.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "agent_id" => %{"type" => "string", "description" => "Agent id from spawn_agent"}
          },
          "required" => ["agent_id"]
        }
      },
      %{
        "name" => "list_agents",
        "description" => "List all live Shem agents with their status, goal, and event count.",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "stop_agent",
        "description" => "Stop a running Shem agent by id.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "agent_id" => %{"type" => "string", "description" => "Agent id from spawn_agent"}
          },
          "required" => ["agent_id"]
        }
      },
      %{
        "name" => "provide_turn",
        "description" =>
          "Supply the next turn for a client-brained agent; content is plain text — embed a {\"tool\":…,\"args\":…} JSON object to call a tool, or plain text to finish.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "agent_id" => %{"type" => "string", "description" => "Agent id from spawn_agent"},
            "turn_token" => %{
              "type" => "string",
              "description" => "Turn token from agent_status (format: turn:nonce)"
            },
            "content" => %{"type" => "string", "description" => "Turn content or tool call JSON"}
          },
          "required" => ["agent_id", "turn_token", "content"]
        }
      },
      %{
        "name" => "install_pack",
        "description" =>
          "Install a git-distributed tool pack. Clones the repo and re-runs each tool through the graduation gate before trusting it; rejected tools are reported, not installed.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "repo" => %{"type" => "string", "description" => "Git URL of the pack repo"},
            "path" => %{"type" => "string", "description" => "Subdirectory containing pack.json (default repo root)"}
          },
          "required" => ["repo"]
        }
      },
      %{
        "name" => "uninstall_pack",
        "description" => "Remove all tools installed from a named pack.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Pack name"}
          },
          "required" => ["name"]
        }
      },
      %{
        "name" => "list_packs",
        "description" => "List installed tool packs (name, version, tool ids).",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    ]
  end
end
