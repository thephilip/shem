defmodule Shem.Counterfactual.Report do
  @moduledoc """
  Structured divergence report for a counterfactual run (ROADMAP Phase 9):
  diff typed events, not prose. Findings vocabulary follows `Shem.Replay.Check`
  (maps with an index and a detail, tool calls as name + args digest).

  Per branch: turns taken, tool calls in order, terminal status, final
  content, premise digest, and the branch's own fork coordinates (its last
  `:llm_call_completed`) so the caller can recurse. Cross-branch:
  first-divergence index and tool-call set deltas, each measured against the
  parent's own post-fork continuation.

  Payload hygiene: premises/contents live in full inside branch sessions (they
  are the record); anything parent-side carries digests (`:tool_invoked`
  precedent). `digest/0` is SHA-256 over the canonical-JSON report, so the
  `:counterfactual_completed` / `:counterfactual_selected` events commit to
  the report's content.
  """

  alias Shem.EventLog

  @spec build(String.t(), String.t(), [String.t()]) :: map()
  def build(parent_sid, fork_event_id, branch_sids) do
    {:ok, parent_events} = EventLog.read_session_events(parent_sid)

    before_count = Enum.count(Enum.take_while(parent_events, &(&1.id != fork_event_id)))
    parent_tail = Enum.drop(parent_events, before_count + 1)
    parent_trace = trace(parent_tail)

    # branch layout: :branch_created + copied prefix (before_count) + fork event
    branch_drop = before_count + 2
    branches = Enum.map(branch_sids, &branch_summary(&1, branch_drop))

    cross = %{
      first_divergence:
        Map.new(branches, fn b -> {b.session_id, first_divergence(parent_trace, b.tool_calls)} end),
      tool_call_deltas:
        Map.new(branches, fn b -> {b.session_id, deltas(parent_trace, b.tool_calls)} end)
    }

    report = %{
      parent: %{
        session_id: parent_sid,
        fork_event_id: fork_event_id,
        turns: Enum.count(parent_tail, &(&1.type == :agent_turn_completed)),
        tool_calls: parent_trace,
        final_content: final_content(parent_tail)
      },
      branches: branches,
      cross: cross
    }

    Map.put(report, :digest, digest(report))
  end

  # ── per branch ───────────────────────────────────────────────────────────────

  defp branch_summary(sid, drop) do
    {:ok, events} = EventLog.read_session_events(sid)
    # the fork event carries the premise (alt_response content)
    premise =
      case Enum.at(events, drop - 1) do
        %{type: :llm_call_completed, payload: %{content: c}} when is_binary(c) -> c
        _ -> ""
      end

    tail = Enum.drop(events, drop)

    %{
      session_id: sid,
      premise_digest: hexdigest(premise),
      turns: Enum.count(tail, &(&1.type == :agent_turn_completed)),
      tool_calls: trace(tail),
      terminal_status: terminal_status(tail),
      final_content: final_content(tail),
      fork_event_id: last_llm_event_id(events)
    }
  end

  defp terminal_status(tail) do
    tail
    |> Enum.reverse()
    |> Enum.find_value("finalized", fn
      %{type: :agent_done} -> "done"
      %{type: :agent_error} -> "error"
      _ -> nil
    end)
  end

  defp trace(events) do
    for e <- events, e.type == :agent_tool_called do
      %{name: e.payload[:tool], args_digest: hexdigest(e.payload[:args])}
    end
  end

  defp final_content(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{type: :agent_done, payload: %{content: c}} when is_binary(c) -> c
      %{type: :llm_call_completed, payload: %{content: c}} when is_binary(c) -> c
      _ -> nil
    end)
  end

  defp last_llm_event_id(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn e -> if e.type == :llm_call_completed, do: e.id end)
  end

  # ── cross-branch ─────────────────────────────────────────────────────────────

  # index of the first differing {name, args_digest}; nil for identical traces
  defp first_divergence(parent_trace, branch_trace) do
    parent_trace
    |> Enum.zip(branch_trace)
    |> Enum.find_index(fn {p, b} -> p != b end)
    |> case do
      nil ->
        if length(parent_trace) == length(branch_trace),
          do: nil,
          else: min(length(parent_trace), length(branch_trace))

      idx ->
        idx
    end
  end

  defp deltas(parent_trace, branch_trace) do
    p = MapSet.new(parent_trace, & &1.name)
    b = MapSet.new(branch_trace, & &1.name)

    %{extra: b |> MapSet.difference(p) |> Enum.sort(),
      missing: p |> MapSet.difference(b) |> Enum.sort()}
  end

  # ── digests ──────────────────────────────────────────────────────────────────

  defp digest(report),
    do: hexdigest(Shem.Attest.CanonicalJSON.encode(report))

  defp hexdigest(term) when is_binary(term),
    do: :crypto.hash(:sha256, term) |> Base.encode16(case: :lower)

  defp hexdigest(term),
    do: hexdigest(:erlang.term_to_binary(term))
end
