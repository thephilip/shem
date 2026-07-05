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

  def handle_call(:await, _from, %{status: s} = state) when s in [:done, :error, :waiting] do
    {:reply, {:ok, s}, state}
  end

  def handle_call(:await, from, state) do
    {:noreply, %{state | awaiting: [from | state.awaiting]}}
  end

  def handle_call(:session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  def handle_call(:info, _from, state) do
    {:reply,
     %{status: state.status, turn_count: state.turn_count, session_id: state.session_id,
       awaiting_prompt: state.awaiting_prompt, turn_token: state.turn_token}, state}
  end

  def handle_call({:message, _text}, _from, %{status: s} = state) when s != :waiting do
    {:reply, {:error, :not_waiting}, state}
  end

  def handle_call({:message, text}, _from, state) do
    EventLog.append(state.session_id, :user_message, %{content: text})
    new_history = state.history ++ [%{role: :user, content: text}]
    send(self(), :run_turn)
    {:reply, :ok, %{state | history: new_history, status: :running}}
  end

  def handle_call({:set_fence, path}, _from, state) do
    {:reply, :ok, %{state | config: %{state.config | fence: path}}}
  end

  # NOTE: :paused status is not persisted in checkpoints. If Horde
  # redistributes a paused agent to another node, init/1 restores history
  # and turn_count but restarts in :running — the pause does not survive
  # node failure. Documented limitation; persisting it requires a
  # checkpoint schema change (deferred).
  def handle_call(:pause, _from, %{status: :running} = state) do
    EventLog.append(state.session_id, :agent_paused, %{turn: state.turn_count})
    {:reply, :ok, %{state | status: :paused}}
  end

  def handle_call(:pause, _from, state), do: {:reply, {:error, :not_running}, state}

  def handle_call({:steer, text}, _from, %{status: :paused} = state) do
    EventLog.append(state.session_id, :agent_steered, %{content: text})
    {:reply, :ok, %{state | history: state.history ++ [%{role: :user, content: text}]}}
  end

  def handle_call({:steer, _text}, _from, state), do: {:reply, {:error, :not_paused}, state}

  def handle_call(:unpause, _from, %{status: :paused} = state) do
    EventLog.append(state.session_id, :agent_unpaused, %{turn: state.turn_count})
    send(self(), :run_turn)
    {:reply, :ok, %{state | status: :running}}
  end

  def handle_call(:unpause, _from, state), do: {:reply, {:error, :not_paused}, state}

  def handle_call(:flush_checkpoint, _from, state) do
    Checkpoint.save(state.session_id, state)
    {:reply, :ok, %{state | status: :evacuating}}
  end

  def handle_call(:evac_spec, _from, state) do
    {:reply, {state.name, state.config, state.session_id}, state}
  end

  def handle_call({:provide_turn, token, content}, _from, %{status: :awaiting_turn, turn_token: token} = state) do
    manifest = ToolDispatch.build_manifest(state.config)
    response = %Shem.LLM.Response{content: content, tokens_used: 0, model: state.config.model, latency_ms: 0}
    pipeline = [{Shem.LLM.Middleware.EventLogger, []},
                {Shem.LLM.Middleware.OneShot, response: response}]
    Process.put(:shem_replay_pipeline, pipeline)
    turn_result =
      try do
        Turn.step(state.config, state.session_id, state.history, manifest)
      after
        Process.delete(:shem_replay_pipeline)
      end

    {:noreply, new_state} = apply_turn_result(turn_result, state, manifest)
    {:reply, {:ok, reply_for(new_state)}, new_state}
  end

  def handle_call({:provide_turn, _token, _content}, _from, state),
    do: {:reply, {:error, :stale_turn}, state}

  defp reply_for(%{status: :awaiting_turn} = s),
    do: %{status: :awaiting_turn, prompt: s.awaiting_prompt, turn_token: s.turn_token}
  defp reply_for(%{status: :done} = s), do: %{status: :done, output: final_output(s)}
  defp reply_for(%{status: :error} = s), do: %{status: :error, reason: inspect(s.done_reason)}
  defp reply_for(%{status: :waiting} = s), do: %{status: :waiting, output: final_output(s)}

  defp final_output(state) do
    state.history
    |> Enum.filter(&(&1.role == :assistant))
    |> List.last()
    |> case do
      %{content: c} when is_binary(c) -> c
      _ -> ""
    end
  end

  # ── Init ────────────────────────────────────────────────────────────────────

  @impl true
  def init({name, config, session_id}) do
    config = prepend_project_context(config)
    # Replay support: a config-carried pipeline overrides the app LLM pipeline
    # for every call this agent makes. provide_turn's put/delete never collides —
    # pipeline-carrying replay agents are brain: :model, provide_turn is :client.
    if config.pipeline, do: Process.put(:shem_replay_pipeline, config.pipeline)
    Process.put(:spawn_agent_depth, config.spawn_depth)
    {:ok, ^session_id} = EventLog.start_session(session_id)

    {history, turn_count} =
      case Checkpoint.reconstruct(session_id) do
        :not_found ->
          EventLog.append(session_id, :agent_started, %{
            task: config.task,
            model: config.model,
            max_turns: config.max_turns,
            preset: config.preset,
            project_context: config.project_context && Map.from_struct(config.project_context)
          })
          {[%{role: :user, content: config.task}], 0}

        {:ok, checkpoint} ->
          # EventLog.append failures in init are non-fatal — consistent with all other append call sites in this module.
          EventLog.append(session_id, :agent_resumed, %{
            node: Node.self(),
            prior_node: Map.get(checkpoint, :node),
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
      awaiting: [],
      awaiting_prompt: nil,
      turn_token: nil
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
      not state.config.conversational and state.turn_count >= state.config.max_turns ->
        {:noreply, finish(state, :done, :max_turns_reached)}

      # Client-brained agents make no paid LLM calls (the brain is the MCP client;
      # OneShot returns canned content with tokens_used: 0), so they consume no LLM
      # budget and must not be preempted by other agents' usage exhausting it.
      state.config.brain != :client and LLM.BudgetServer.check() == {:error, :budget_exhausted} ->
        {:noreply, finish(state, :done, :budget_exhausted)}

      true ->
        EventLog.append(state.session_id, :agent_turn_started, %{turn: state.turn_count + 1})
        manifest = ToolDispatch.build_manifest(state.config)

        if state.config.brain == :client do
          {:noreply, park(state, manifest)}
        else
          turn_meta = %{session_id: state.session_id, node: node()}

          turn_result =
            :telemetry.span(
              [:shem, :agent, :turn],
              turn_meta,
              fn -> {Turn.stream_step(state.config, state.session_id, state.history, manifest), turn_meta} end
            )

          apply_turn_result(turn_result, state, manifest)
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp park(state, manifest) do
    prompt = Turn.build_prompt(state.config.system_prompt, manifest, state.history)
    token = {state.turn_count + 1, System.unique_integer([:positive])}
    EventLog.append(state.session_id, :agent_awaiting_turn, %{turn: state.turn_count + 1, prompt: prompt})
    Enum.each(:pg.get_members(:shem_streams, state.session_id), fn pid ->
      send(pid, {:stream_chunk, state.session_id, prompt})
    end)
    %{state | status: :awaiting_turn, awaiting_prompt: prompt, turn_token: token}
  end

  defp apply_turn_result(turn_result, state, manifest) do
    case turn_result do
      {:done, answer, rc} ->
        emit_thinking(state.session_id, state.turn_count + 1, rc)
        history = state.history ++ [%{role: :assistant, content: answer}]
        EventLog.append(state.session_id, :agent_turn_completed, %{turn: state.turn_count + 1, outcome: :done})
        {:noreply, finish(%{state | history: history, turn_count: state.turn_count + 1}, :done, :answer)}

      {:tool_calls, calls, raw, rc} ->
        emit_thinking(state.session_id, state.turn_count + 1, rc)
        assistant_entry = %{role: :assistant, content: (if raw == "", do: nil, else: raw), tool_calls: calls}
        history = state.history ++ [assistant_entry]
        history = execute_tool_calls(calls, manifest, history, state.session_id, state.config)
        EventLog.append(state.session_id, :agent_turn_completed, %{turn: state.turn_count + 1, outcome: :tool_calls})
        new_state = %{state | history: history, turn_count: state.turn_count + 1}
        case new_state.config.brain do
          :client -> {:noreply, park(new_state, manifest)}
          _ -> send(self(), :run_turn); {:noreply, new_state}
        end

      {:error, reason} ->
        EventLog.append(state.session_id, :agent_error, %{reason: inspect(reason)})
        {:noreply, finish(state, :error, reason)}
    end
  end

  defp execute_tool_calls(calls, manifest, history, session_id, config) do
    backend = Application.get_env(:shem, :resolved_executor_backend, Shem.Lab.Executor.Backend.Local)
    opts = [fence: config.fence, backend: backend, policy: config.policy]

    Enum.reduce(calls, history, fn call, acc ->
      EventLog.append(session_id, :agent_tool_called, %{tool: call.name, args: call.args})

      result_str =
        case ToolDispatch.execute(call, manifest, opts) do
          {:ok, result} -> result
          {:error, reason} -> "Error: #{reason}"
        end

      EventLog.append(session_id, :agent_tool_result, %{tool: call.name, result: result_str})
      acc ++ [%{role: :tool, tool_call_id: call.id, content: "Tool result (#{call.name}): #{result_str}"}]
    end)
  end

  defp finish(%{config: %Config{conversational: true}} = state, _status, :answer) do
    last_content =
      state.history
      |> Enum.filter(&(&1.role == :assistant))
      |> List.last()
      |> case do
        %{content: c} when is_binary(c) -> c
        _ -> ""
      end

    EventLog.append(state.session_id, :agent_waiting, %{content: last_content})
    broadcast_stream_done(state.session_id)
    Enum.each(state.awaiting, fn from -> GenServer.reply(from, {:ok, :waiting}) end)
    %{state | status: :waiting, done_reason: :waiting, awaiting: []}
  end

  defp finish(state, status, :answer) do
    last_content =
      state.history
      |> Enum.filter(&(&1.role == :assistant))
      |> List.last()
      |> Map.get(:content, "")

    EventLog.append(state.session_id, :agent_done, %{reason: :answer, content: last_content})
    EventLog.finalize(state.session_id)
    broadcast_stream_done(state.session_id)
    Enum.each(state.awaiting, fn from -> GenServer.reply(from, {:ok, status}) end)
    %{state | status: status, done_reason: :answer, awaiting: []}
  end

  defp finish(state, status, reason) do
    EventLog.append(state.session_id, :agent_done, %{reason: reason})
    EventLog.finalize(state.session_id)
    broadcast_stream_done(state.session_id)
    Enum.each(state.awaiting, fn from -> GenServer.reply(from, {:ok, status}) end)
    %{state | status: status, done_reason: reason, awaiting: []}
  end

  defp broadcast_stream_done(session_id) do
    Enum.each(:pg.get_members(:shem_streams, session_id), fn pid ->
      send(pid, {:stream_done, session_id})
    end)
  end

  defp emit_thinking(_session_id, _turn, rc) when rc in [nil, ""], do: :ok
  defp emit_thinking(session_id, turn, rc) do
    EventLog.append(session_id, :agent_thinking, %{content: rc, turn: turn})
    Enum.each(:pg.get_members(:shem_streams, session_id), fn pid ->
      send(pid, {:stream_thinking, session_id, rc})
    end)
  end

  defp prepend_project_context(%Config{project_context: nil} = config), do: config
  defp prepend_project_context(%Config{project_context: ctx, system_prompt: sp} = config) do
    preamble = Shem.Context.Project.to_prompt(ctx)
    %{config | system_prompt: preamble <> "\n" <> sp}
  end
end
