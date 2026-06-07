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

  get "/:id/result" do
    case Shem.Agent.await(id, 100) do
      {:ok, :done} ->
        {:ok, session_id} = Shem.Agent.session_id(id)
        content = read_done_content(session_id)
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

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
