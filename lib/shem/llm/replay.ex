defmodule Shem.LLM.Replay do
  alias Shem.LLM.Replay.Utils

  @spec with_replay(String.t(), (String.t() -> result)) ::
          {:ok, String.t(), result} | {:error, term()}
        when result: term()
  def with_replay(original_session_id, fun) when is_function(fun, 1) do
    with {:ok, queue} <- extract_queue(original_session_id) do
      Utils.run_with_pipeline(queue, fun)
    end
  end

  @spec diff(String.t(), String.t()) :: [map()]
  def diff(session_a_id, session_b_id) do
    with {:ok, events_a} <- Shem.EventLog.events(session_a_id),
         {:ok, events_b} <- Shem.EventLog.events(session_b_id) do
      calls_a = extract_call_summaries(events_a)
      calls_b = extract_call_summaries(events_b)
      compare_calls(calls_a, calls_b)
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp extract_queue(session_id) do
    # read_session_events (not events/1) so a golden recorded in a PRIOR process
    # — no active handle, only its DETS/Mnesia record — still replays.
    case Shem.EventLog.read_session_events(session_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, events} ->
        queue =
          events
          |> Utils.extract_llm_pairs()
          |> Utils.build_queue_from_pairs()

        cond do
          queue == [] ->
            {:error, :no_llm_events}

          Enum.any?(queue, fn e -> Map.has_key?(e, :content) and is_nil(e[:content]) end) ->
            {:error, :no_llm_events}

          true ->
            {:ok, queue}
        end
    end
  end

  defp extract_call_summaries(events) do
    events
    |> Utils.extract_llm_pairs()
    |> Enum.with_index()
    |> Enum.map(fn {{started, outcome}, idx} ->
      %{
        call_index: idx,
        prompt: started.payload[:prompt],
        content: outcome.payload[:content],
        outcome: outcome.type
      }
    end)
  end

  defp compare_calls(calls_a, calls_b) do
    max_len = max(length(calls_a), length(calls_b))

    if max_len == 0 do
      []
    else
      Enum.flat_map(0..(max_len - 1), fn i ->
        a = Enum.at(calls_a, i)
        b = Enum.at(calls_b, i)

        cond do
          is_nil(a) ->
            [%{call_index: i, type: :missing_in_original, original: nil, replay: b}]

          is_nil(b) ->
            [%{call_index: i, type: :missing_in_replay, original: a, replay: nil}]

          a.prompt != b.prompt ->
            [%{call_index: i, type: :prompt_diverged, original: a, replay: b}]

          true ->
            []
        end
      end)
    end
  end
end
