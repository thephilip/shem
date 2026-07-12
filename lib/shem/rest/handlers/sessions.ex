defmodule Shem.REST.Handlers.Sessions do
  use Plug.Router

  alias Shem.EventLog
  alias Shem.EventLog.HistoryScanner
  alias Shem.MCP.Handlers.AgentCommon
  alias Shem.Sessions.Fork

  plug :match
  plug :dispatch

  get "/" do
    sessions = list_all_sessions()
    send_json(conn, 200, sessions)
  end

  get "/:id/events" do
    case EventLog.read_session_events(id) do
      {:ok, events} ->
        send_json(conn, 200, Enum.map(events, &format_event/1))

      {:error, _} ->
        send_json(conn, 404, %{error: "session not found"})
    end
  end

  post "/:id/fork" do
    fork_event_id = Map.get(conn.body_params, "fork_event_id")
    alt_response = Map.get(conn.body_params, "alt_response")
    continue = Map.get(conn.body_params, "continue", false)

    if is_nil(fork_event_id) do
      send_json(conn, 400, %{error: "fork_event_id is required"})
    else
      with {:ok, events} <- EventLog.read_session_events(id),
           {:ok, fork_event} <- Fork.find_fork_event(events, fork_event_id),
           {:ok, new_session_id} <- Fork.build_fork(id, events, fork_event, alt_response, continue) do
        send_json(conn, 201, fork_response(new_session_id, events, continue))
      else
        {:error, :not_found} -> send_json(conn, 404, %{error: "session not found"})
        {:error, :fork_event_not_found} -> send_json(conn, 422, %{error: "fork_event_id not found in session"})
        {:error, :not_llm_call} -> send_json(conn, 422, %{error: "fork_event_id must point to an llm_call_completed event"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end
  end

  get "/:id/verify" do
    case Shem.EventLog.verify_chain(id) do
      {:ok, :verified, n} ->
        send_json(conn, 200, %{verified: true, events: n})

      {:ok, :verified_gc, %{pruned: pruned, replayable: m}} ->
        send_json(conn, 200, %{verified: true, events: m, pruned: pruned,
          note: "events 1-#{pruned} pruned, digest intact; remainder fully replayable"})

      {:ok, :legacy, n} ->
        n = if is_map(n), do: n.replayable, else: n
        send_json(conn, 200, %{verified: "legacy", events: n})

      {:error, {:broken_at, event_id}} ->
        send_json(conn, 200, %{verified: false, broken_at: event_id})

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "session not found"})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp list_all_sessions do
    in_memory =
      case EventLog.list_sessions() do
        {:ok, sessions} -> sessions
        _ -> []
      end

    active_ids =
      in_memory
      |> Enum.filter(&is_nil(&1.ended_at))
      |> Enum.map(& &1.id)
      |> MapSet.new()

    active =
      in_memory
      |> Enum.filter(&is_nil(&1.ended_at))
      |> Enum.map(&format_active_session/1)

    historical =
      HistoryScanner.scan()
      |> Enum.reject(&MapSet.member?(active_ids, &1.session_id))
      |> Enum.map(&format_historical_session/1)

    (active ++ historical)
    |> Enum.sort_by(&(&1.started_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})
  end

  defp format_active_session(session) do
    {task, turn_count} =
      case EventLog.read_session_events(session.id) do
        {:ok, events} ->
          task =
            events
            |> Enum.find(&(&1.type == :agent_started))
            |> case do
              nil -> nil
              e -> e.payload[:task]
            end

          turns = Enum.count(events, &(&1.type == :agent_turn_completed))
          {task, turns}

        _ ->
          {nil, 0}
      end

    # The live agent's real status (a parked client-brain agent is
    # "awaiting_turn", which the WebUI co-driver strip keys off).
    status =
      with {:ok, name} <- AgentCommon.find_by_session(session.id),
           {:ok, info} <- Shem.Agent.info(name) do
        Atom.to_string(info.status)
      else
        _ -> "running"
      end

    %{
      session_id: session.id,
      task: task,
      started_at: session.started_at,
      status: status,
      turn_count: turn_count,
      active: true
    }
  end

  defp format_historical_session(%HistoryScanner{} = s) do
    status =
      case s.status do
        :done -> "done"
        :error -> "error"
        :running -> "running"
        :fork -> "fork"
        _ -> "unknown"
      end

    %{
      session_id: s.session_id,
      task: s.task,
      started_at: s.started_at,
      status: status,
      turn_count: s.turn_count,
      active: false
    }
  end

  defp format_event(event) do
    %{
      id: event.id,
      type: event.type,
      timestamp: event.timestamp,
      parent_id: event.parent_id,
      payload: sanitize_payload(event.payload)
    }
  end

  defp sanitize_payload(v) when is_struct(v) do
    v |> Map.from_struct() |> sanitize_payload()
  end

  defp sanitize_payload(v) when is_map(v) do
    Map.new(v, fn {k, val} -> {k, sanitize_payload(val)} end)
  end

  defp sanitize_payload(v) when is_list(v), do: Enum.map(v, &sanitize_payload/1)

  defp sanitize_payload(v) when is_tuple(v) do
    v |> Tuple.to_list() |> Enum.map(&sanitize_payload/1)
  end

  defp sanitize_payload(v), do: v

  # continue: false → static finalized fork; continue: true → live, resumed.
  # The browser co-driver drives resumed forks, so brain: :client by contract.
  defp fork_response(new_session_id, _events, false), do: %{session_id: new_session_id}

  defp fork_response(new_session_id, events, true) do
    case Fork.resume_fork(new_session_id, events, brain: :client) do
      {:ok, agent_id} -> %{session_id: new_session_id, agent_id: agent_id, continued: true}
      {:error, reason} -> %{session_id: new_session_id, continued: false, error: inspect(reason)}
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
