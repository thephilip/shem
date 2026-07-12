defmodule Shem.Counterfactual.ReportTest do
  use ExUnit.Case, async: false

  alias Shem.Counterfactual.Report
  alias Shem.EventLog
  alias Shem.Sessions.Fork

  # Parent: fork point, then a post-fork continuation that calls tool "a".
  # Branch A repeats the parent's tool call; branch B calls tool "b" instead.
  defp seed do
    {:ok, parent} = EventLog.start_session()
    {:ok, _} = EventLog.append(parent, :agent_started, %{task: "report test", preset: "general", max_turns: 20, brain: :client})
    {:ok, fork_ev} = EventLog.append(parent, :llm_call_completed, %{content: "original decision"})
    {:ok, _} = EventLog.append(parent, :agent_tool_called, %{tool: "a", args: %{x: 1}})
    {:ok, _} = EventLog.append(parent, :agent_turn_completed, %{turn: 2, outcome: :tool_calls})
    {:ok, _} = EventLog.append(parent, :agent_done, %{reason: :answer, content: "parent outcome"})
    {:ok, events} = EventLog.read_session_events(parent)

    {:ok, branch_a} = Fork.build_fork(parent, events, fork_ev, "premise A", true)
    {:ok, _} = EventLog.append(branch_a, :agent_tool_called, %{tool: "a", args: %{x: 1}})
    {:ok, _} = EventLog.append(branch_a, :agent_turn_completed, %{turn: 2, outcome: :tool_calls})
    {:ok, _} = EventLog.append(branch_a, :llm_call_completed, %{content: "A outcome"})
    {:ok, _} = EventLog.append(branch_a, :agent_done, %{reason: :answer, content: "A outcome"})
    :ok = EventLog.finalize(branch_a)

    {:ok, branch_b} = Fork.build_fork(parent, events, fork_ev, "premise B", true)
    {:ok, _} = EventLog.append(branch_b, :agent_tool_called, %{tool: "b", args: %{y: 2}})
    {:ok, _} = EventLog.append(branch_b, :agent_turn_completed, %{turn: 2, outcome: :tool_calls})
    {:ok, _} = EventLog.append(branch_b, :agent_error, %{reason: "boom"})
    :ok = EventLog.finalize(branch_b)

    %{parent: parent, fork_ev: fork_ev, a: branch_a, b: branch_b}
  end

  test "per-branch summaries + cross-branch divergence vs the parent continuation" do
    %{parent: parent, fork_ev: fork_ev, a: a, b: b} = seed()

    report = Report.build(parent, fork_ev.id, [a, b])

    assert [ra, rb] = report.branches
    assert ra.session_id == a
    assert rb.session_id == b

    # premise digests differ and are hex
    assert ra.premise_digest =~ ~r/^[0-9a-f]{64}$/
    assert ra.premise_digest != rb.premise_digest

    assert ra.turns == 1
    assert [%{name: "a", args_digest: da}] = ra.tool_calls
    assert da =~ ~r/^[0-9a-f]{64}$/
    assert ra.terminal_status == "done"
    assert ra.final_content == "A outcome"
    # recursion pointer: branch A's last llm_call_completed
    assert is_binary(ra.fork_event_id)

    assert [%{name: "b"}] = rb.tool_calls
    assert rb.terminal_status == "error"

    # branch A mirrors the parent's continuation → no divergence;
    # branch B diverges at the first tool call
    assert report.cross.first_divergence[a] == nil
    assert report.cross.first_divergence[b] == 0
    assert report.cross.tool_call_deltas[a] == %{extra: [], missing: []}
    assert report.cross.tool_call_deltas[b] == %{extra: ["b"], missing: ["a"]}

    assert report.digest =~ ~r/^[0-9a-f]{64}$/
  end

  test "digest is stable across builds" do
    %{parent: parent, fork_ev: fork_ev, a: a, b: b} = seed()
    r1 = Report.build(parent, fork_ev.id, [a, b])
    r2 = Report.build(parent, fork_ev.id, [a, b])
    assert r1.digest == r2.digest
  end
end
