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
         {:ok, events} <- Shem.EventLog.read_session_events(golden_sid),
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
        cond do
          # Recorded before replay-check support — no preset field at all.
          not Map.has_key?(payload, :preset) ->
            {:error, :not_replayable}

          # Raw-Config start (preset: nil): the agent ran with its own
          # system_prompt, which agent_started does NOT record, so we can't
          # reconstruct the prompt — replaying against "general" would spuriously
          # diverge. Refuse rather than mislead.
          is_nil(payload[:preset]) ->
            {:error, :not_replayable}

          true ->
            ctx = payload[:project_context] && struct(Shem.Context.Project, payload[:project_context])
            {:ok, payload[:task], payload[:preset], ctx}
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

  # ── Presentation + CLI ──────────────────────────────────────────────────────

  @tail 160

  @spec format(Report.t()) :: String.t()
  def format(%Report{} = r) do
    header = "replaying #{r.golden_sid} (#{r.recorded_calls} LLM calls recorded)"

    body = Enum.map(r.findings, &format_finding/1)

    result =
      if Report.clean?(r) do
        "result: CLEAN — replay matches the recording"
      else
        "result: DIVERGED — #{length(r.findings)} finding(s) across #{r.recorded_calls} recorded calls"
      end

    footer = "replay session: #{r.replay_sid} (inspect at /timeline)"

    Enum.join([header] ++ body ++ [result, footer], "\n")
  end

  # Call indexes are 0-based internally, 1-based for humans.
  defp format_finding(%{class: :prompt_diverged, call_index: i, recorded: rec, replayed: rep}) do
    "✕ call #{i + 1}: prompt diverged\n" <>
      "    recorded  …#{tail(rec)}\n" <>
      "    replayed  …#{tail(rep)}"
  end

  defp format_finding(%{class: :extra_calls, detail: d}), do: "✕ extra calls: #{d}"
  defp format_finding(%{class: :unused_calls, detail: d}), do: "✕ unused calls: #{d}"
  defp format_finding(%{class: :replay_error, detail: d}), do: "✕ replay error: #{d}"

  defp tail(s) when byte_size(s) <= @tail, do: s
  defp tail(s), do: binary_part(s, byte_size(s) - @tail, @tail)

  @spec format_error(String.t(), term()) :: String.t()
  def format_error(sid, :not_found) do
    data_dir = Application.get_env(:shem, :event_log_path, Path.join([System.user_home!(), ".config", "shem", "lab", "events"]))
    "session #{sid} not found (data dir: #{data_dir})"
  end

  def format_error(sid, :not_replayable),
    do:
      "session #{sid} is not replayable (recorded before replay-check support, or " <>
        "started from a raw Config with no preset) — re-record the golden via a preset"

  def format_error(sid, {:chain_broken, detail}),
    do: "session #{sid}: hash chain broken (#{inspect(detail)}) — golden is not trustworthy"

  def format_error(sid, :not_an_agent_session), do: "session #{sid} has no agent_started event"
  def format_error(sid, :no_llm_events), do: "session #{sid} has no recorded LLM calls"
  def format_error(_sid, {:preset_unknown, name}), do: "preset #{inspect(name)} no longer exists"
  def format_error(sid, other), do: "replay of #{sid} failed: #{inspect(other)}"

  @doc """
  One-shot entry for `shem replay --check` / `mix shem.replay`.
  Boots the app headless and RETURNS the exit code — callers halt.
  """
  @spec cli(String.t()) :: 0 | 1 | 2
  def cli(golden_sid) do
    Application.put_env(:shem, :start_tui, false)
    Application.put_env(:shem, :start_cluster, false)
    # Ephemeral port: this instance exists only for the replay.
    Application.put_env(:shem, :mcp_port, 0)
    {:ok, _} = Application.ensure_all_started(:shem)

    case run(golden_sid) do
      {:ok, report} ->
        IO.puts(format(report))
        if Report.clean?(report), do: 0, else: 1

      {:error, reason} ->
        IO.puts(:stderr, format_error(golden_sid, reason))
        2
    end
  end
end
