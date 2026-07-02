defmodule Shem.REST.Handlers.Agents do
  use Plug.Router

  alias Shem.MCP.Handlers.{AgentCommon, ProvideTurn}

  plug :match
  plug :dispatch

  post "/" do
    resume_session_id = Map.get(conn.body_params, "resume_session_id")
    preset = Map.get(conn.body_params, "preset", "general")
    task = Map.get(conn.body_params, "task")
    conversational = Map.get(conn.body_params, "conversational", false)

    cond do
      resume_session_id ->
        task_str = task || extract_task_from_session(resume_session_id) || "Resumed session"

        case Shem.Agent.resume(resume_session_id, task_str) do
          {:ok, agent_id, session_id} ->
            send_json(conn, 201, %{agent_id: agent_id, session_id: session_id})

          {:error, reason} ->
            send_json(conn, 500, %{error: inspect(reason)})
        end

      is_nil(task) or task == "" ->
        send_json(conn, 400, %{error: "task is required"})

      true ->
        case Shem.Agent.start_with_preset(preset, task, conversational: conversational) do
          {:ok, agent_id, session_id} ->
            send_json(conn, 201, %{agent_id: agent_id, session_id: session_id})

          {:error, :not_found} ->
            send_json(conn, 400, %{error: "unknown preset: #{preset}"})

          {:error, reason} ->
            send_json(conn, 500, %{error: inspect(reason)})
        end
    end
  end

  get "/" do
    agents =
      Horde.DynamicSupervisor.which_children(Shem.AgentSupervisor)
      |> Enum.filter(fn {_id, pid, _, _} -> is_pid(pid) end)
      |> Enum.map(fn {name, pid, _, _} ->
        session_id =
          case Shem.ProcessRegistry.lookup(name) do
            {_p, sid} -> sid
            _ -> nil
          end

        status =
          try do
            case GenServer.call(pid, :status, 200) do
              {:ok, s} -> Atom.to_string(s)
              _ -> "unknown"
            end
          catch
            :exit, _ -> "unknown"
          end

        %{
          name: to_string(name),
          agent_id: session_id,
          status: status,
          node: Atom.to_string(node(pid))
        }
      end)

    send_json(conn, 200, %{agents: agents})
  end

  get "/:id/stream" do
    case Shem.Agent.session_id(id) do
      {:error, :not_found} ->
        send_json(conn, 404, %{error: "agent not found"})

      {:ok, session_id} ->
        conn =
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(200)

        :pg.join(:shem_streams, session_id, self())
        stream_loop(conn, session_id)
    end
  end

  get "/:id/result" do
    case Shem.Agent.await(id, 100) do
      {:ok, :done} ->
        content =
          case Shem.Agent.session_id(id) do
            {:ok, session_id} -> read_done_content(session_id)
            {:error, :not_found} -> ""
          end
        send_json(conn, 200, %{status: "done", content: content})

      {:ok, :error} ->
        send_json(conn, 200, %{status: "error", error: "agent failed"})

      {:error, :timeout} ->
        send_json(conn, 200, %{status: "running"})

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "agent not found"})
    end
  end

  get "/:id/shadow" do
    case Shem.Shadow.Agent.current_score(id) do
      {:ok, %{band: band, score: score, reasoning: reasoning}} ->
        send_json(conn, 200, %{band: band, score: score, reasoning: reasoning})

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "shadow agent not found for: #{id}"})
    end
  end

  get "/:id" do
    with {:ok, name} <- resolve_agent(id),
         {:ok, info} <- Shem.Agent.info(name) do
      node_str =
        case Shem.ProcessRegistry.lookup(name) do
          {pid, _} -> Atom.to_string(node(pid))
          nil -> nil
        end

      base = %{status: info.status, node: node_str}

      base =
        if info.status == :awaiting_turn do
          Map.merge(base, %{
            prompt: info.awaiting_prompt,
            turn_token: ProvideTurn.encode_token(info.turn_token)
          })
        else
          base
        end

      send_json(conn, 200, base)
    else
      _ -> send_json(conn, 404, %{error: "agent not found"})
    end
  end

  delete "/:id" do
    case Shem.Agent.stop(id) do
      :ok -> send_json(conn, 200, %{ok: true})
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
    end
  end

  post "/:id/message" do
    message = Map.get(conn.body_params, "message")

    if is_nil(message) or message == "" do
      send_json(conn, 400, %{error: "message is required"})
    else
      case Shem.Agent.send_message(id, message) do
        :ok ->
          send_json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "agent not found"})

        {:error, :not_waiting} ->
          send_json(conn, 409, %{error: "agent is not waiting for input"})

        {:error, :timeout} ->
          send_json(conn, 503, %{error: "agent timed out"})
      end
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  defp extract_task_from_session(session_id) do
    case Shem.EventLog.read_session_events(session_id) do
      {:ok, events} ->
        events
        |> Enum.find(&(&1.type == :agent_started))
        |> case do
          nil -> nil
          e -> e.payload[:task]
        end

      _ ->
        nil
    end
  end

  defp read_done_content(session_id) do
    case Shem.EventLog.events(session_id) do
      {:ok, events} ->
        events
        |> Enum.filter(&(&1.type == :agent_done))
        |> List.last()
        |> case do
          nil -> ""
          event -> Map.get(event.payload, :content, "")
        end

      _ ->
        ""
    end
  end

  defp stream_loop(conn, session_id) do
    receive do
      {:stream_chunk, ^session_id, token} ->
        event = Jason.encode!(%{type: "chunk", content: token})

        case Plug.Conn.chunk(conn, "data: #{event}\n\n") do
          {:ok, conn} -> stream_loop(conn, session_id)
          {:error, _} ->
            :pg.leave(:shem_streams, session_id, self())
            conn
        end

      {:stream_thinking, ^session_id, rc} ->
        event = Jason.encode!(%{type: "thinking", content: rc})

        case Plug.Conn.chunk(conn, "data: #{event}\n\n") do
          {:ok, conn} -> stream_loop(conn, session_id)
          {:error, _} ->
            :pg.leave(:shem_streams, session_id, self())
            conn
        end

      {:stream_done, ^session_id} ->
        event = Jason.encode!(%{type: "done", status: "done"})
        Plug.Conn.chunk(conn, "data: #{event}\n\n")
        :pg.leave(:shem_streams, session_id, self())
        conn

      _other ->
        stream_loop(conn, session_id)
    after
      30_000 ->
        :pg.leave(:shem_streams, session_id, self())
        conn
    end
  end

  # Accept an agent process name or an EventLog session id (what the WebUI holds).
  defp resolve_agent(id) do
    case Shem.Agent.info(id) do
      {:ok, _} -> {:ok, id}
      {:error, :not_found} -> AgentCommon.find_by_session(id)
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
