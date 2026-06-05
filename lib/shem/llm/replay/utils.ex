defmodule Shem.LLM.Replay.Utils do
  alias Shem.LLM.ReplayTransport
  alias Shem.LLM.Middleware.{BudgetCheck, EventLogger}
  alias Shem.LLM.BudgetServer

  @spec run_with_pipeline([map()], (String.t() -> result)) :: {:ok, String.t(), result}
        when result: term()
  def run_with_pipeline(queue, fun) when is_function(fun, 1) do
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
      {:ok, session_id} = Shem.EventLog.start_session()
      result = fun.(session_id)
      {:ok, session_id, result}
    after
      Process.delete(:shem_replay_pipeline)
      GenServer.stop(server_name, :normal, 1_000)
    end
  end

  @spec extract_llm_pairs([Shem.EventLog.Event.t()]) ::
          [{Shem.EventLog.Event.t(), Shem.EventLog.Event.t()}]
  def extract_llm_pairs(events) do
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

  @spec build_queue_from_pairs([{Shem.EventLog.Event.t(), Shem.EventLog.Event.t()}]) :: [map()]
  def build_queue_from_pairs(pairs) do
    Enum.map(pairs, fn
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
  end
end
