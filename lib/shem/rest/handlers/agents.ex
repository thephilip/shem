defmodule Shem.REST.Handlers.Agents do
  use Plug.Router

  plug :match
  plug :dispatch

  post "/" do
    preset = Map.get(conn.body_params, "preset", "general")
    task = Map.get(conn.body_params, "task")

    if is_nil(task) or task == "" do
      send_json(conn, 400, %{error: "task is required"})
    else
      case Shem.Agent.start_with_preset(preset, task) do
        {:ok, agent_id} ->
          {:ok, session_id} = Shem.Agent.session_id(agent_id)
          send_json(conn, 201, %{agent_id: agent_id, session_id: session_id})

        {:error, :not_found} ->
          send_json(conn, 400, %{error: "unknown preset: #{preset}"})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    end
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

        Registry.register(Shem.StreamRegistry, session_id, nil)
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

  get "/:id" do
    case Shem.Agent.status(id) do
      {:ok, status} -> send_json(conn, 200, %{status: status})
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
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
            Registry.unregister(Shem.StreamRegistry, session_id)
            conn
        end

      {:stream_done, ^session_id} ->
        event = Jason.encode!(%{type: "done", status: "done"})
        Plug.Conn.chunk(conn, "data: #{event}\n\n")
        Registry.unregister(Shem.StreamRegistry, session_id)
        conn

      _other ->
        stream_loop(conn, session_id)
    after
      30_000 ->
        Registry.unregister(Shem.StreamRegistry, session_id)
        conn
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
