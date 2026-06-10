defmodule Shem.Shadow.Agent do
  use GenServer

  alias Shem.{EventLog, ProcessRegistry}
  alias Shem.Shadow.Prompt

  @spec start_link({String.t(), String.t(), pid()}) :: GenServer.on_start()
  def start_link({agent_name, session_id, agent_pid}) do
    via = ProcessRegistry.via_tuple("shadow_#{agent_name}")
    GenServer.start_link(__MODULE__, {agent_name, session_id, agent_pid}, name: via)
  end

  @spec current_score(String.t()) ::
          {:ok, %{band: :high | :medium | :low, score: float(), reasoning: String.t()}}
          | {:error, :not_found}
  def current_score(agent_name) do
    via = ProcessRegistry.via_tuple("shadow_#{agent_name}")
    case GenServer.whereis(via) do
      nil ->
        {:error, :not_found}

      pid ->
        try do
          GenServer.call(pid, :current_score)
        catch
          :exit, _ -> {:error, :not_found}
        end
    end
  end

  @impl true
  def init({agent_name, session_id, agent_pid}) do
    _ref = Process.monitor(agent_pid)
    poll_ms = Application.get_env(:shem, :shadow_agent_poll_ms, 2_000)
    Process.send_after(self(), :check, poll_ms)

    {:ok,
     %{
       agent_name: agent_name,
       session_id: session_id,
       score: 1.0,
       band: :high,
       reasoning: "No analysis yet.",
       last_event_count: 0,
       status: :idle,
       task: nil,
       analysis_timer_ref: nil
     }}
  end

  @impl true
  def handle_call(:current_score, _from, state) do
    {:reply, {:ok, %{band: state.band, score: state.score, reasoning: state.reasoning}}, state}
  end

  @impl true
  def handle_info(:check, state) do
    poll_ms = Application.get_env(:shem, :shadow_agent_poll_ms, 2_000)
    Process.send_after(self(), :check, poll_ms)
    {:noreply, maybe_analyze(state)}
  end

  def handle_info({:shadow_result, score, reasoning}, state) do
    if state.analysis_timer_ref, do: Process.cancel_timer(state.analysis_timer_ref)
    band = score_to_band(score)
    {:noreply, %{state | score: score, band: band, reasoning: reasoning, status: :idle, analysis_timer_ref: nil}}
  end

  def handle_info({:shadow_error, _reason}, state) do
    if state.analysis_timer_ref, do: Process.cancel_timer(state.analysis_timer_ref)
    {:noreply, %{state | status: :idle, analysis_timer_ref: nil}}
  end

  def handle_info(:shadow_analysis_timeout, state) do
    {:noreply, %{state | status: :idle, analysis_timer_ref: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_analyze(%{status: :analyzing} = state), do: state

  defp maybe_analyze(state) do
    case EventLog.read_session_events(state.session_id) do
      {:ok, events} when length(events) > state.last_event_count ->
        new_events = Enum.drop(events, state.last_event_count)
        relevant_types = [:agent_tool_called, :agent_tool_result, :agent_turn_completed, :agent_checkpoint]

        if Enum.any?(new_events, &(&1.type in relevant_types)) do
          task = find_task(events, state.task)
          parent = self()

          Task.start(fn ->
            result =
              try do
                run_analysis(task, events)
              rescue
                _ -> {:shadow_error, :analysis_raised}
              catch
                :exit, _ -> {:shadow_error, :analysis_exit}
              end

            send(parent, result)
          end)

          ref = Process.send_after(self(), :shadow_analysis_timeout, 60_000)
          %{state | status: :analyzing, last_event_count: length(events), task: task, analysis_timer_ref: ref}
        else
          %{state | last_event_count: length(events)}
        end

      {:ok, events} ->
        %{state | last_event_count: length(events)}

      _ ->
        state
    end
  end

  defp find_task(_events, task) when is_binary(task), do: task

  defp find_task(events, nil) do
    case Enum.find(events, &(&1.type == :agent_started)) do
      nil -> "unknown task"
      event -> Map.get(event.payload, :task, "unknown task")
    end
  end

  defp run_analysis(task, events) do
    request = %Shem.LLM.Request{
      prompt: Prompt.build(task, events),
      model: :shadow,
      session_id: nil,
      system: Prompt.system_prompt(),
      tools: []
    }

    case Shem.LLM.complete(request) do
      {:ok, %{content: content}} when is_binary(content) ->
        parse_result(content)

      _ ->
        {:shadow_error, :llm_failed}
    end
  end

  defp parse_result(content) do
    with {:ok, %{"score" => score, "reasoning" => reasoning}} <- Jason.decode(content),
         true <- is_number(score),
         true <- score >= 0.0 and score <= 1.0 do
      {:shadow_result, score * 1.0, reasoning}
    else
      _ -> {:shadow_error, :parse_failed}
    end
  end

  defp score_to_band(score) when score >= 0.7, do: :high
  defp score_to_band(score) when score >= 0.4, do: :medium
  defp score_to_band(_), do: :low
end
