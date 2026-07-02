defmodule Shem.Replay.Check do
  @moduledoc """
  Deterministic golden-session replay (ROADMAP Phase 3): re-run a recorded
  agent session with the RECORDED LLM responses (no model called) and report
  where the replay diverged.

  Semantics: code-under-test resolves live (current preset prompt, current
  tool manifest and behavior); environment replays from the record (task,
  project context, LLM responses). A changed prompt/tool shows up as a
  divergence at a specific call index; directory drift does not.
  """

  alias Shem.LLM.Replay.Utils

  defmodule Report do
    defstruct golden_sid: nil, replay_sid: nil, recorded_calls: 0, findings: []

    @type t :: %__MODULE__{}

    def clean?(%__MODULE__{findings: findings}), do: findings == []
  end

  @await_timeout 60_000

  @spec run(String.t(), keyword()) :: {:ok, Report.t()} | {:error, term()}
  def run(golden_sid, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @await_timeout)

    with :ok <- verify(golden_sid),
         {:ok, events} <- Shem.EventLog.events(golden_sid),
         {:ok, task, preset_name, ctx} <- replay_fields(events),
         {:ok, config} <- build_config(task, preset_name, ctx) do
      recorded = length(Utils.extract_llm_pairs(events))

      case Shem.LLM.Replay.with_replay(golden_sid, fn replay_sid ->
             replay_agent(config, replay_sid, timeout)
           end) do
        {:ok, replay_sid, agent_outcome} ->
          {:ok, build_report(golden_sid, replay_sid, recorded, agent_outcome)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ── Golden inspection ───────────────────────────────────────────────────────

  defp verify(golden_sid) do
    case Shem.EventLog.verify_chain(golden_sid) do
      {:ok, _kind, _count} -> :ok
      {:error, :not_found} -> {:error, :not_found}
      {:error, broken} -> {:error, {:chain_broken, broken}}
    end
  end

  defp replay_fields(events) do
    case Enum.find(events, &(&1.type == :agent_started)) do
      nil ->
        {:error, :not_an_agent_session}

      %{payload: payload} ->
        if Map.has_key?(payload, :preset) do
          ctx = payload[:project_context] && struct(Shem.Context.Project, payload[:project_context])
          {:ok, payload[:task], payload[:preset], ctx}
        else
          # Recorded before replay-check support — cannot reconstruct the run.
          {:error, :not_replayable}
        end
    end
  end

  defp build_config(task, preset_name, ctx) do
    case Shem.Agent.Preset.resolve(preset_name || "general") do
      {:ok, preset} ->
        {:ok,
         %Shem.Agent.Config{
           task: task,
           system_prompt: preset.system_prompt,
           tools: if(preset.tools == :all, do: [], else: preset.tools),
           max_turns: preset.max_turns,
           project_context: ctx,
           preset: preset_name
         }}

      _ ->
        {:error, {:preset_unknown, preset_name}}
    end
  end

  # ── Replay run (inside with_replay's pipeline scope) ────────────────────────

  defp replay_agent(config, replay_sid, timeout) do
    # with_replay put the replay pipeline in OUR pdict; hand it to the agent
    # process via config so the real server runs every call through it.
    config = %{config | pipeline: Process.get(:shem_replay_pipeline)}
    name = "replay_" <> Base.encode16(:crypto.strong_rand_bytes(4))

    case Shem.AgentSupervisor.start_agent(name, config, replay_sid) do
      {:ok, _pid} ->
        case Shem.Agent.await(name, timeout) do
          {:ok, _status} -> :completed
          {:error, :timeout} -> {:agent_failed, :await_timeout}
          {:error, reason} -> {:agent_failed, reason}
        end

      {:error, reason} ->
        {:agent_failed, {:start_failed, reason}}
    end
  end

  # ── Report assembly ─────────────────────────────────────────────────────────

  defp build_report(golden_sid, replay_sid, recorded, agent_outcome) do
    {:ok, revents} = Shem.EventLog.events(replay_sid)

    diverged =
      for e <- revents, e.type == :llm_call_diverged do
        %{
          class: :prompt_diverged,
          call_index: e.payload[:call_index],
          recorded: e.payload[:original_prompt] || "",
          replayed: e.payload[:replay_prompt] || ""
        }
      end

    exhausted? = Enum.any?(revents, &(&1.type == :replay_exhausted))

    extra =
      if exhausted?,
        do: [%{class: :extra_calls, detail: "agent required more LLM calls than the #{recorded} recorded"}],
        else: []

    replayed_calls = length(Utils.extract_llm_pairs(revents))

    unused =
      if not exhausted? and replayed_calls < recorded,
        do: [%{class: :unused_calls, detail: "agent used #{replayed_calls} of #{recorded} recorded calls"}],
        else: []

    # Agent errors caused by queue exhaustion are already reported as :extra_calls.
    errors =
      for e <- revents,
          e.type == :agent_error,
          not (exhausted? and e.payload[:reason] =~ "replay_exhausted") do
        %{class: :replay_error, detail: e.payload[:reason]}
      end

    errors =
      case agent_outcome do
        :completed -> errors
        {:agent_failed, reason} -> errors ++ [%{class: :replay_error, detail: inspect(reason)}]
      end

    %Report{
      golden_sid: golden_sid,
      replay_sid: replay_sid,
      recorded_calls: recorded,
      findings: diverged ++ extra ++ unused ++ errors
    }
  end
end
