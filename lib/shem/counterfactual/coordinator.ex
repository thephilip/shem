defmodule Shem.Counterfactual.Coordinator do
  @moduledoc """
  One per counterfactual run: executes variant branches SEQUENTIALLY (parallel
  is an explicit non-goal — PortPool/container capacity), polling each resumed
  agent to terminal or the wall-clock cap. A parked client-brain branch blocks
  the queue until the caller finishes steering it via `provide_turn` — v1
  drives one branch at a time, and the wall clock includes parked time
  (documented in the tool descriptor; per-state clocks if a real dogfood run
  gets bitten).

  In-memory status only: the durable record is the parent session's
  `:counterfactual_run` / `:counterfactual_completed` events. This process
  dying loses nothing but live polling (`status/1` reconstructs, coordinator:
  "not_live").
  """

  use GenServer, restart: :temporary

  alias Shem.EventLog
  alias Shem.Counterfactual.Report
  alias Shem.Sessions.Fork

  @poll_ms 200

  def start_link(args) do
    GenServer.start_link(__MODULE__, args,
      name: {:via, Registry, {Shem.Counterfactual.Registry, args.run_id}}
    )
  end

  @impl true
  def init(args) do
    branches =
      Enum.map(args.branches, fn b ->
        Map.merge(b, %{status: "queued", agent_id: nil, deadline: nil})
      end)

    state =
      args
      |> Map.put(:branches, branches)
      |> Map.put(:idx, 0)
      |> Map.put(:report, nil)
      |> Map.put(:base_turns, turns_at_fork(args.parent_events, args.fork_event))

    send(self(), :advance)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, status_view(state)}, state}
  end

  @impl true
  def handle_info(:advance, %{idx: idx, branches: branches} = state)
      when idx >= length(branches) do
    report =
      Report.build(state.parent_sid, state.fork_event.id, Enum.map(branches, & &1.session_id))

    Shem.Counterfactual.append_reopened(state.parent_sid, :counterfactual_completed, %{
      run_id: state.run_id,
      report_digest: report.digest,
      branch_statuses: Map.new(branches, &{&1.session_id, &1.status})
    })

    {:noreply, %{state | report: report}}
  end

  def handle_info(:advance, state) do
    b = Enum.at(state.branches, state.idx)
    :ok = EventLog.reopen(b.session_id)

    # Total-turn cap = turns already replayed at the fork + this run's budget:
    # the resumed agent's turn_count continues from the copied history, so
    # capping at the raw budget would trip max_turns_reached immediately.
    opts =
      Fork.resume_opts(state.parent_events) ++
        [max_turns: state.base_turns + state.max_turns] ++
        policy_opts(state.deny_actions)

    case Shem.Agent.resume(b.session_id, Fork.task_from_events(state.parent_events), opts) do
      {:ok, agent_id, _} ->
        deadline = System.monotonic_time(:millisecond) + state.wall_clock_ms
        state = put_branch(state, %{b | status: "running", agent_id: agent_id, deadline: deadline})
        Process.send_after(self(), :poll, @poll_ms)
        {:noreply, state}

      {:error, reason} ->
        EventLog.append(b.session_id, :agent_error, %{reason: inspect(reason)})
        EventLog.finalize(b.session_id)
        finish_branch(state, "error")
    end
  end

  def handle_info(:poll, state) do
    b = Enum.at(state.branches, state.idx)

    case Shem.Agent.info(b.agent_id) do
      {:ok, %{status: s}} when s in [:done, :waiting] ->
        Shem.Agent.stop(b.agent_id)
        finish_branch(state, "done")

      {:ok, %{status: :error}} ->
        Shem.Agent.stop(b.agent_id)
        finish_branch(state, "error")

      {:ok, _running_or_awaiting} ->
        if System.monotonic_time(:millisecond) > b.deadline do
          Shem.Agent.stop(b.agent_id)
          EventLog.finalize(b.session_id)
          finish_branch(state, "timeout")
        else
          Process.send_after(self(), :poll, @poll_ms)
          {:noreply, state}
        end

      {:error, _not_found} ->
        # agent process gone (crash/handoff) — the log has the ending
        finish_branch(state, Shem.Counterfactual.terminal_from_log(b.session_id))
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp finish_branch(state, status) do
    b = Enum.at(state.branches, state.idx)
    state = put_branch(state, %{b | status: status})
    send(self(), :advance)
    {:noreply, %{state | idx: state.idx + 1}}
  end

  defp put_branch(state, branch) do
    %{state | branches: List.replace_at(state.branches, state.idx, branch)}
  end

  defp policy_opts(nil), do: []
  defp policy_opts([]), do: []
  defp policy_opts(deny) when is_list(deny), do: [policy: %{deny: deny}]

  # Mirrors Checkpoint.reconstruct's arithmetic: last checkpoint's turn_count
  # plus one turn per llm_call_completed after it, up to and including the fork.
  defp turns_at_fork(events, fork_event) do
    upto = Enum.take_while(events, &(&1.id != fork_event.id)) ++ [fork_event]

    case upto |> Enum.filter(&(&1.type == :agent_checkpoint)) |> List.last() do
      nil ->
        Enum.count(upto, &(&1.type == :llm_call_completed))

      cp ->
        tail = upto |> Enum.drop_while(&(&1.id != cp.id)) |> Enum.drop(1)
        Map.get(cp.payload, :turn_count, 0) + Enum.count(tail, &(&1.type == :llm_call_completed))
    end
  end

  defp status_view(state) do
    branches =
      state.branches
      |> Enum.with_index()
      |> Enum.map(fn {b, i} ->
        base = %{session_id: b.session_id, status: b.status, agent_id: b.agent_id, prompt: nil}

        if i == state.idx and b.agent_id do
          case Shem.Agent.info(b.agent_id) do
            {:ok, %{status: s} = info} ->
              %{base | status: Atom.to_string(s), prompt: Map.get(info, :awaiting_prompt)}

            _ ->
              base
          end
        else
          base
        end
      end)

    %{
      status: if(state.report, do: "complete", else: "running"),
      branches: branches,
      report: state.report,
      coordinator: "live"
    }
  end
end
