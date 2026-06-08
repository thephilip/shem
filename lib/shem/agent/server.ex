defmodule Shem.Agent.Server do
  use GenServer

  alias Shem.Agent.{Config, Turn, ToolDispatch, Checkpoint}
  alias Shem.{EventLog, LLM}

  def start_link({name, %Config{} = config, session_id, opts}) do
    GenServer.start_link(__MODULE__, {name, config, session_id}, opts)
  end

  # ── Client API ──────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, state.status}, state}
  end

  def handle_call(:await, _from, %{status: s} = state) when s in [:done, :error] do
    {:reply, {:ok, s}, state}
  end

  def handle_call(:await, from, state) do
    {:noreply, %{state | awaiting: [from | state.awaiting]}}
  end

  def handle_call(:session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  # ── Init ────────────────────────────────────────────────────────────────────

  @impl true
  def init({name, config, session_id}) do
    Process.put(:spawn_agent_depth, config.spawn_depth)
    {:ok, ^session_id} = EventLog.start_session(session_id)

    {history, turn_count} =
      case Checkpoint.reconstruct(session_id) do
        :not_found ->
          EventLog.append(session_id, :agent_started, %{
            task: config.task,
            model: config.model,
            max_turns: config.max_turns
          })
          {[%{role: :user, content: config.task}], 0}

        {:ok, checkpoint} ->
          EventLog.append(session_id, :agent_resumed, %{
            node: Node.self(),
            turn: checkpoint.turn_count
          })
          {checkpoint.history, checkpoint.turn_count}
      end

    state = %{
      name: name,
      config: config,
      history: history,
      session_id: session_id,
      turn_count: turn_count,
      status: :running,
      done_reason: nil,
      awaiting: []
    }

    send(self(), :run_turn)
    {:ok, state}
  end

  # ── Loop ────────────────────────────────────────────────────────────────────

  @impl true
  def handle_info(:run_turn, %{status: s} = state) when s != :running do
    {:noreply, state}
  end

  def handle_info(:run_turn, state) do
    case Checkpoint.save(state.session_id, state) do
      :ok -> :ok
      {:error, reason} ->
        require Logger
        Logger.warning("Checkpoint save failed for session #{state.session_id}: #{inspect(reason)}")
    end

    cond do
      state.turn_count >= state.config.max_turns ->
        {:noreply, finish(state, :done, :max_turns_reached)}

      LLM.BudgetServer.check() == {:error, :budget_exhausted} ->
        {:noreply, finish(state, :done, :budget_exhausted)}

      true ->
        EventLog.append(state.session_id, :agent_turn_started, %{turn: state.turn_count + 1})
        manifest = ToolDispatch.build_manifest(state.config)

        case Turn.stream_step(state.config, state.session_id, state.history, manifest) do
          {:done, answer} ->
            history = state.history ++ [%{role: :assistant, content: answer}]
            EventLog.append(state.session_id, :agent_turn_completed, %{
              turn: state.turn_count + 1,
              outcome: :done
            })
            {:noreply,
             finish(%{state | history: history, turn_count: state.turn_count + 1}, :done, :answer)}

          {:tool_calls, calls, raw} ->
            assistant_entry = %{
              role: :assistant,
              content: (if raw == "", do: nil, else: raw),
              tool_calls: calls
            }
            history = state.history ++ [assistant_entry]
            history = execute_tool_calls(calls, manifest, history, state.session_id)
            EventLog.append(state.session_id, :agent_turn_completed, %{
              turn: state.turn_count + 1,
              outcome: :tool_calls
            })
            new_state = %{state | history: history, turn_count: state.turn_count + 1}
            send(self(), :run_turn)
            {:noreply, new_state}

          {:error, reason} ->
            EventLog.append(state.session_id, :agent_error, %{reason: inspect(reason)})
            {:noreply, finish(state, :error, reason)}
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp execute_tool_calls(calls, manifest, history, session_id) do
    Enum.reduce(calls, history, fn call, acc ->
      EventLog.append(session_id, :agent_tool_called, %{tool: call.name, args: call.args})

      result_str =
        case ToolDispatch.execute(call, manifest) do
          {:ok, result} -> result
          {:error, reason} -> "Error: #{reason}"
        end

      EventLog.append(session_id, :agent_tool_result, %{tool: call.name, result: result_str})
      acc ++ [%{role: :tool, tool_call_id: call.id, content: "Tool result (#{call.name}): #{result_str}"}]
    end)
  end

  defp finish(state, status, :answer) do
    last_content =
      state.history
      |> Enum.filter(&(&1.role == :assistant))
      |> List.last()
      |> Map.get(:content, "")

    EventLog.append(state.session_id, :agent_done, %{reason: :answer, content: last_content})
    broadcast_stream_done(state.session_id)
    Enum.each(state.awaiting, fn from -> GenServer.reply(from, {:ok, status}) end)
    %{state | status: status, done_reason: :answer, awaiting: []}
  end

  defp finish(state, status, reason) do
    EventLog.append(state.session_id, :agent_done, %{reason: reason})
    broadcast_stream_done(state.session_id)
    Enum.each(state.awaiting, fn from -> GenServer.reply(from, {:ok, status}) end)
    %{state | status: status, done_reason: reason, awaiting: []}
  end

  defp broadcast_stream_done(session_id) do
    Registry.dispatch(Shem.StreamRegistry, session_id, fn entries ->
      Enum.each(entries, fn {pid, _} -> send(pid, {:stream_done, session_id}) end)
    end)
  end
end
