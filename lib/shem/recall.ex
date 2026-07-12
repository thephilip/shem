defmodule Shem.Recall do
  @moduledoc """
  Recall: lexical search over all past EventLog sessions, answered with
  replayable evidence. Hits carry the coordinates of the nearest
  `:llm_call_completed` event so the caller can fork right there via
  `POST /api/sessions/:id/fork`. Every query is itself appended to a
  dedicated hash-chained session — the reach-rate instrument.

  `context/4` verifies the session's hash chain before serving its events —
  a chain-broken (tampered) session is refused with `{:error, :chain_broken}`
  rather than returned as memory, even if the caller supplies exact
  coordinates for a tampered event.
  """

  require Logger

  alias Shem.Recall.{Index, Scanner, Text}

  @snippet_len 200

  @spec search(String.t(), pos_integer(), keyword()) :: {:ok, map()}
  def search(query, limit \\ 5, opts \\ []) do
    index = Keyword.get(opts, :index, Index)
    %{hits: raw_hits, skipped: skipped, indexed_sessions: indexed} = Index.search(index, query, limit)

    hits =
      raw_hits
      |> Enum.group_by(& &1.session_id)
      |> Enum.flat_map(fn {sid, session_hits} -> shape_hits(sid, session_hits) end)
      |> Enum.sort_by(& &1.score, :desc)

    status =
      cond do
        indexed == 0 -> "no_sessions_indexed"
        hits == [] -> "no_matches"
        true -> "ok"
      end

    log_query(query, hits)
    {:ok, %{status: status, hits: hits, skipped: skipped}}
  end

  @spec context(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, :session_not_found | :event_not_found | :chain_broken}
  def context(session_id, event_id, radius \\ 3, _opts \\ []) do
    with {:ok, events} <- session_events(session_id),
         :ok <- check_chain(session_id),
         idx when not is_nil(idx) <- Enum.find_index(events, &(&1.id == event_id)) do
      lo = max(idx - radius, 0)

      window =
        events
        |> Enum.slice(lo..(idx + radius))
        |> Enum.map(fn e ->
          %{event_id: e.id, seq: e.seq, event_type: to_string(e.type),
            timestamp: e.timestamp, payload: e.payload}
        end)

      {:ok, %{session_id: session_id, events: window,
              fork: fork_pointer(session_id, events, event_id)}}
    else
      nil -> {:error, :event_not_found}
      {:error, :chain_broken} -> {:error, :chain_broken}
      {:error, _} -> {:error, :session_not_found}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp session_events(session_id) do
    case Scanner.events(session_id) do
      {:ok, [_ | _] = events} -> {:ok, events}
      _ -> {:error, :session_not_found}
    end
  end

  # A chain-broken log is tampered/corrupt evidence — never serve it as
  # memory. Mirrors Shem.Recall.Index.check_chain/1: legacy (nil-hash) and
  # GC-verified outcomes pass through as before.
  defp check_chain(session_id) do
    case Shem.EventLog.verify_chain(session_id) do
      {:error, {:broken_at, _event_id}} -> {:error, :chain_broken}
      _ -> :ok
    end
  end

  defp shape_hits(session_id, session_hits) do
    case session_events(session_id) do
      {:ok, events} ->
        Enum.flat_map(session_hits, fn %{event_id: event_id, score: score} ->
          case Enum.find(events, &(&1.id == event_id)) do
            nil ->
              []

            e ->
              [%{
                session_id: session_id,
                event_id: e.id,
                seq: e.seq,
                event_type: to_string(e.type),
                timestamp: e.timestamp,
                score: score,
                snippet: e.payload |> Text.flatten() |> String.slice(0, @snippet_len),
                fork: fork_pointer(session_id, events, e.id)
              }]
          end
        end)

      {:error, _} ->
        []
    end
  end

  # Nearest :llm_call_completed at-or-before the matched event — the only
  # event type the REST fork endpoint accepts as fork_event_id.
  defp fork_pointer(session_id, events, event_id) do
    idx = Enum.find_index(events, &(&1.id == event_id)) || 0

    fork_event_id =
      events
      |> Enum.take(idx + 1)
      |> Enum.reverse()
      |> Enum.find_value(fn e -> if e.type == :llm_call_completed, do: e.id end)

    %{fork_event_id: fork_event_id, endpoint: "POST /api/sessions/#{session_id}/fork"}
  end

  defp log_query(query, hits) do
    sid = Scanner.query_session_id()

    with {:ok, _} <- Shem.EventLog.start_session(sid),
         {:ok, _} <-
           Shem.EventLog.append(sid, :recall_query, %{
             query: query,
             hit_count: length(hits),
             top_sessions: hits |> Enum.map(& &1.session_id) |> Enum.uniq() |> Enum.take(3)
           }) do
      :ok
    else
      err -> Logger.warning("recall: query log append failed: #{inspect(err)}")
    end
  rescue
    e -> Logger.warning("recall: query log append failed: #{Exception.format(:error, e, __STACKTRACE__)}")
  catch
    kind, reason -> Logger.warning("recall: query log append failed: #{inspect({kind, reason})}")
  end
end
