defmodule Shem.LLM.Branch do
  alias Shem.LLM.Replay.Utils

  @type alt_entry ::
          %{content: String.t(), tokens_used: non_neg_integer()}
          | %{content: String.t(), tokens_used: non_neg_integer(), label: String.t()}
          | %{error: String.t()}

  @type diff_entry :: %{
          call_index: non_neg_integer(),
          type: :identical | :content_differs,
          branches: [%{label: String.t(), content: String.t() | nil, prompt: String.t() | nil}]
        }

  @spec branch_at(String.t(), String.t(), [alt_entry()], (String.t() -> result)) ::
          {:ok, String.t(), result} | {:error, term()}
        when result: term()
  def branch_at(original_session_id, fork_event_id, alt_queue, fun)
      when is_function(fun, 1) do
    with {:ok, events} <- fetch_events_with_llm_check(original_session_id),
         {:ok, fork_index} <- find_fork_event_index(events, fork_event_id) do
      prefix_queue = build_prefix_queue(events, fork_index)
      full_queue = prefix_queue ++ normalize_alt_queue(alt_queue)

      Utils.run_with_pipeline(full_queue, fn session_id ->
        Shem.EventLog.append(session_id, :branch_created, %{
          original_session_id: original_session_id,
          fork_event_id: fork_event_id,
          alt_count: length(alt_queue)
        })

        fun.(session_id)
      end)
    end
  end

  @spec branch_after_call(String.t(), non_neg_integer(), [alt_entry()], (String.t() -> result)) ::
          {:ok, String.t(), result} | {:error, term()}
        when result: term()
  def branch_after_call(original_session_id, call_index, alt_queue, fun)
      when is_function(fun, 1) and is_integer(call_index) and call_index >= 0 do
    case Shem.EventLog.events(original_session_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, events} ->
        pairs = Utils.extract_llm_pairs(events)

        case Enum.at(pairs, call_index) do
          nil -> {:error, :call_index_out_of_range}
          {_started, outcome_event} -> branch_at(original_session_id, outcome_event.id, alt_queue, fun)
        end
    end
  end

  @spec compare([{String.t(), String.t()}]) :: [diff_entry()] | {:error, term()}
  def compare(labelled_sessions) when is_list(labelled_sessions) do
    results =
      Enum.map(labelled_sessions, fn {label, session_id} ->
        case Shem.EventLog.events(session_id) do
          {:error, reason} ->
            {:error, reason}

          {:ok, events} ->
            summaries =
              events
              |> Utils.extract_llm_pairs()
              |> Enum.with_index()
              |> Enum.map(fn {{started, outcome}, idx} ->
                %{
                  call_index: idx,
                  label: label,
                  prompt: started.payload[:prompt],
                  content: outcome.payload[:content]
                }
              end)

            {:ok, label, summaries}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        max_len =
          results
          |> Enum.map(fn {:ok, _label, summaries} -> length(summaries) end)
          |> Enum.max(fn -> 0 end)

        if max_len == 0 do
          []
        else
          Enum.map(0..(max_len - 1), fn i ->
            entries =
              Enum.map(results, fn {:ok, label, summaries} ->
                case Enum.at(summaries, i) do
                  nil -> %{label: label, prompt: nil, content: nil}
                  s -> %{label: label, prompt: s.prompt, content: s.content}
                end
              end)

            contents = Enum.map(entries, & &1.content)
            type = if length(Enum.uniq(contents)) == 1, do: :identical, else: :content_differs

            %{call_index: i, type: type, branches: entries}
          end)
        end
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp fetch_events_with_llm_check(session_id) do
    case Shem.EventLog.events(session_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, events} ->
        if Utils.extract_llm_pairs(events) == [] do
          {:error, :no_llm_events}
        else
          {:ok, events}
        end
    end
  end

  defp find_fork_event_index(events, fork_event_id) do
    case Enum.find_index(events, &(&1.id == fork_event_id)) do
      nil -> {:error, :fork_event_not_found}
      index -> {:ok, index}
    end
  end

  defp normalize_alt_queue(alt_queue) do
    Enum.map(alt_queue, fn entry ->
      if Map.has_key?(entry, :error) do
        entry
      else
        Map.put_new(entry, :prompt, nil)
      end
    end)
  end

  defp build_prefix_queue(events, fork_index) do
    events
    |> Enum.take(fork_index + 1)
    |> Utils.extract_llm_pairs()
    |> Utils.build_queue_from_pairs()
  end
end
