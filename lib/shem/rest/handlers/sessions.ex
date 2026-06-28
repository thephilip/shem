defmodule Shem.REST.Handlers.Sessions do
  use Plug.Router

  alias Shem.EventLog
  alias Shem.EventLog.HistoryScanner

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

    if is_nil(fork_event_id) do
      send_json(conn, 400, %{error: "fork_event_id is required"})
    else
      with {:ok, events} <- EventLog.read_session_events(id),
           {:ok, fork_event} <- find_fork_event(events, fork_event_id),
           {:ok, new_session_id} <- build_fork(events, fork_event, alt_response) do
        send_json(conn, 201, %{session_id: new_session_id})
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

      {:ok, :legacy, n} ->
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

    %{
      session_id: session.id,
      task: task,
      started_at: session.started_at,
      status: "running",
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

  defp find_fork_event(events, fork_event_id) do
    case Enum.find(events, &(&1.id == fork_event_id)) do
      nil -> {:error, :fork_event_not_found}
      event when event.type == :llm_call_completed -> {:ok, event}
      _event -> {:error, :not_llm_call}
    end
  end

  defp build_fork(events, fork_event, alt_response) do
    case EventLog.start_session() do
      {:ok, new_session_id} ->
        events_before = Enum.take_while(events, &(&1.id != fork_event.id))

        Enum.each(events_before, fn event ->
          EventLog.append(new_session_id, event.type, event.payload)
        end)

        fork_payload =
          if alt_response && alt_response != "" do
            Map.put(fork_event.payload, :content, alt_response)
          else
            fork_event.payload
          end

        EventLog.append(new_session_id, :llm_call_completed, fork_payload)
        # A fork is a static branch snapshot, not a running agent — finalize it
        # immediately so it never shows as a perpetually-"LIVE" session. finalize
        # (not end_session) keeps the handle open so the fork stays readable.
        EventLog.finalize(new_session_id)
        {:ok, new_session_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
