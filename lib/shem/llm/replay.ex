defmodule Shem.LLM.Replay do
  alias Shem.LLM.ReplayTransport
  alias Shem.LLM.Middleware.{BudgetCheck, EventLogger}
  alias Shem.LLM.BudgetServer

  @spec with_replay(String.t(), (String.t() -> result)) ::
          {:ok, String.t(), result} | {:error, term()}
        when result: term()
  def with_replay(original_session_id, fun) when is_function(fun, 1) do
    with {:ok, queue} <- extract_queue(original_session_id) do
      server_name = :"replay_transport_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = ReplayTransport.Server.start_link(name: server_name)

      try do
        ReplayTransport.Server.load(server_name, queue)

        replay_pipeline = [
          {BudgetCheck, [budget_server: BudgetServer]},
          {EventLogger, []},
          {ReplayTransport, [server: server_name]}
        ]

        Process.put(:shem_replay_pipeline, replay_pipeline)
        {:ok, replay_session_id} = Shem.EventLog.start_session()
        result = fun.(replay_session_id)
        {:ok, replay_session_id, result}
      after
        Process.delete(:shem_replay_pipeline)
        GenServer.stop(server_name, :normal, 1_000)
      end
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
    case Shem.EventLog.events(session_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, events} ->
        queue =
          events
          |> pair_llm_events()
          |> Enum.map(fn
            {started, %{type: :llm_call_completed} = completed} ->
              %{
                prompt: started.payload[:prompt],
                content: completed.payload[:content],
                tokens_used: completed.payload[:tokens_used]
              }

            {started, %{type: :llm_call_failed} = failed} ->
              %{
                prompt: started.payload[:prompt],
                error: failed.payload[:reason]
              }
          end)

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

  defp pair_llm_events(events) do
    {_pending, pairs} =
      Enum.reduce(events, {nil, []}, fn event, {pending_start, acc} ->
        case {event.type, pending_start} do
          {:llm_call_started, _} ->
            {event, acc}

          {:llm_call_completed, start} when not is_nil(start) ->
            {nil, [{start, event} | acc]}

          {:llm_call_failed, start} when not is_nil(start) ->
            {nil, [{start, event} | acc]}

          _ ->
            {pending_start, acc}
        end
      end)

    Enum.reverse(pairs)
  end

  defp extract_call_summaries(events) do
    events
    |> pair_llm_events()
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
