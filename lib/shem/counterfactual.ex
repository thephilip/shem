defmodule Shem.Counterfactual do
  @moduledoc """
  Counterfactual fork (ROADMAP Phase 9): run N caller-supplied variant
  premises as live branches from a chosen turn, get a structured divergence
  report, continue on a selected winner. Every branch stays in the log.

  Run state: the source of truth is a `:counterfactual_run` event in the
  parent session (with `:counterfactual_completed` / `:counterfactual_selected`
  closing the record); a per-run `Coordinator` GenServer tracks live status
  for polling. A node restart loses only in-flight status, never the record —
  `status/1` reconstructs from the logs and answers `coordinator: "not_live"`.

  run_id format: `"<parent_session_id>:<counterfactual_run event id>"` —
  self-locating, so reconstruction needs no session scan. Opaque to callers.

  Side-effect boundary (README determinism boundary applies): variants
  re-execute tools LIVE. A counterfactual over a session that used
  side-effecting tools acts again, once per branch. `deny_actions` routes a
  per-run deny list through the existing Guardrails policy.

  Payload hygiene: parent-side events carry premise/report digests only
  (`:tool_invoked` precedent); full text lives in the branch sessions.
  """

  alias Shem.EventLog
  alias Shem.Counterfactual.{Coordinator, Report}
  alias Shem.Sessions.Fork

  @side_effects "variants re-execute tools live"

  @spec side_effects_warning() :: String.t()
  def side_effects_warning, do: @side_effects

  @spec run(String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(parent_sid, fork_event_id, variants, opts \\ []) do
    cfg = config()

    with :ok <- validate_variants(variants, cfg.max_variants),
         {:ok, events} <- read_parent(parent_sid),
         {:ok, fork_event} <- Fork.nearest_at_or_before(events, fork_event_id) do
      max_turns = Keyword.get(opts, :max_turns, cfg.default_max_turns)
      deny_actions = Keyword.get(opts, :deny_actions)

      # forks are created eagerly (static, ids known for the start event); the
      # coordinator reopens each one when its turn comes and resumes it
      branches =
        Enum.map(variants, fn premise ->
          {:ok, branch_sid} = Fork.build_fork(parent_sid, events, fork_event, premise, false)
          %{session_id: branch_sid, premise_digest: hexdigest(premise)}
        end)

      {:ok, run_ev} =
        append_reopened(parent_sid, :counterfactual_run, %{
          fork_event_id: fork_event.id,
          variant_digests: Enum.map(branches, & &1.premise_digest),
          branch_session_ids: Enum.map(branches, & &1.session_id),
          max_turns: max_turns,
          wall_clock_ms: cfg.wall_clock_ms,
          deny_actions: deny_actions,
          side_effects: @side_effects
        })

      run_id = parent_sid <> ":" <> run_ev.id

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Shem.Counterfactual.Supervisor,
          {Coordinator,
           %{
             run_id: run_id,
             parent_sid: parent_sid,
             parent_events: events,
             fork_event: fork_event,
             branches: branches,
             max_turns: max_turns,
             wall_clock_ms: cfg.wall_clock_ms,
             deny_actions: deny_actions
           }}
        )

      {:ok, %{run_id: run_id, branches: branches, status: "running", side_effects: @side_effects}}
    end
  end

  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(run_id) do
    case Registry.lookup(Shem.Counterfactual.Registry, run_id) do
      [{pid, _}] ->
        # the coordinator can die between lookup and call (registry cleanup
        # is async) — a dead coordinator is the reconstruction case, not an error
        try do
          GenServer.call(pid, :status)
        catch
          :exit, _ -> reconstruct_status(run_id)
        end

      [] ->
        reconstruct_status(run_id)
    end
  end

  @spec select(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found | :not_in_run}
  def select(run_id, branch_sid) do
    with {:ok, parent_sid, event_id} <- parse_run_id(run_id),
         {:ok, events} <- read_parent(parent_sid),
         {:ok, payload} <- find_run_payload(events, event_id),
         :ok <- validate_membership(payload, branch_sid) do
      report = Report.build(parent_sid, payload.fork_event_id, payload.branch_session_ids)

      {:ok, _} =
        append_reopened(parent_sid, :counterfactual_selected, %{
          run_id: run_id,
          selected_session_id: branch_sid,
          report_digest: report.digest
        })

      {:ok, branch_events} = EventLog.read_session_events(branch_sid)

      # continue on the winner: a still-live agent (e.g. parked client-brain)
      # is returned as-is; a terminal branch is reopened and resumed with the
      # config threaded from its own copied record
      agent_id =
        case Shem.MCP.Handlers.AgentCommon.find_by_session(branch_sid) do
          {:ok, name} ->
            name

          _ ->
            EventLog.reopen(branch_sid)

            case Fork.resume_fork(branch_sid, branch_events, Fork.resume_opts(branch_events)) do
              {:ok, name} -> name
              {:error, _} -> nil
            end
        end

      {:ok,
       %{session_id: branch_sid, agent_id: agent_id, fork_event_id: last_llm_id(branch_events)}}
    end
  end

  @doc false
  # Append to a session regardless of its lifecycle state: active sessions get
  # a plain append; finalized ones are reopened and refinalized; sessions known
  # only from disk (post-restart) are re-adopted via start_session/1 (which
  # continues last_hash/seq) and finalized after. `ended_at` means "no live
  # writer", not "immutable" — immutability is the hash chain's job.
  def append_reopened(sid, type, payload) do
    case session_state(sid) do
      :active ->
        EventLog.append(sid, type, payload)

      :finalized ->
        :ok = EventLog.reopen(sid)
        result = EventLog.append(sid, type, payload)
        :ok = EventLog.finalize(sid)
        result

      :unknown ->
        {:ok, _} = EventLog.start_session(sid)
        result = EventLog.append(sid, type, payload)
        :ok = EventLog.finalize(sid)
        result
    end
  end

  @doc false
  def hexdigest(term) when is_binary(term),
    do: :crypto.hash(:sha256, term) |> Base.encode16(case: :lower)

  # ── Private ──────────────────────────────────────────────────────────────────

  defp config do
    cfg = Application.get_env(:shem, :counterfactual, %{})

    %{
      max_variants: Map.get(cfg, :max_variants, 4),
      default_max_turns: Map.get(cfg, :default_max_turns, 4),
      wall_clock_ms: Map.get(cfg, :wall_clock_ms, 120_000)
    }
  end

  defp validate_variants(variants, max) when is_list(variants) do
    cond do
      variants == [] -> {:error, :invalid_variants}
      not Enum.all?(variants, &(is_binary(&1) and &1 != "")) -> {:error, :invalid_variants}
      length(variants) > max -> {:error, :too_many_variants}
      true -> :ok
    end
  end

  defp validate_variants(_, _), do: {:error, :invalid_variants}

  defp read_parent(parent_sid) do
    case EventLog.read_session_events(parent_sid) do
      {:ok, events} -> {:ok, events}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp parse_run_id(run_id) when is_binary(run_id) do
    case String.split(run_id, ":", parts: 2) do
      [sid, evt] when sid != "" and evt != "" -> {:ok, sid, evt}
      _ -> {:error, :not_found}
    end
  end

  defp parse_run_id(_), do: {:error, :not_found}

  defp find_run_payload(events, event_id) do
    case Enum.find(events, &(&1.id == event_id and &1.type == :counterfactual_run)) do
      %{payload: payload} -> {:ok, payload}
      _ -> {:error, :not_found}
    end
  end

  defp validate_membership(payload, branch_sid) do
    if branch_sid in payload.branch_session_ids, do: :ok, else: {:error, :not_in_run}
  end

  defp reconstruct_status(run_id) do
    with {:ok, parent_sid, event_id} <- parse_run_id(run_id),
         {:ok, events} <- read_parent(parent_sid),
         {:ok, payload} <- find_run_payload(events, event_id) do
      completed =
        Enum.find(events, &(&1.type == :counterfactual_completed and &1.payload[:run_id] == run_id))

      branches =
        Enum.map(payload.branch_session_ids, fn sid ->
          %{session_id: sid, status: terminal_from_log(sid), agent_id: nil, prompt: nil}
        end)

      report =
        if completed,
          do: Report.build(parent_sid, payload.fork_event_id, payload.branch_session_ids)

      {:ok,
       %{
         status: if(completed, do: "complete", else: "running"),
         branches: branches,
         report: report,
         coordinator: "not_live"
       }}
    end
  end

  @doc false
  def terminal_from_log(sid) do
    case EventLog.read_session_events(sid) do
      {:ok, events} ->
        events
        |> Enum.reverse()
        |> Enum.find_value("unknown", fn
          %{type: :agent_done} -> "done"
          %{type: :agent_error} -> "error"
          _ -> nil
        end)

      _ ->
        "unknown"
    end
  end

  defp last_llm_id(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn e -> if e.type == :llm_call_completed, do: e.id end)
  end

  defp session_state(sid) do
    case EventLog.list_sessions() do
      {:ok, sessions} ->
        case Enum.find(sessions, &(&1.id == sid)) do
          nil -> :unknown
          %{ended_at: nil} -> :active
          _ -> :finalized
        end

      _ ->
        :unknown
    end
  end
end
