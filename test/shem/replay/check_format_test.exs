defmodule Shem.Replay.CheckFormatTest do
  use ExUnit.Case, async: true

  alias Shem.Replay.Check
  alias Shem.Replay.Check.Report

  test "clean report" do
    out =
      Check.format(%Report{golden_sid: "ses_G", replay_sid: "ses_R", recorded_calls: 3, findings: []})

    assert out =~ "replaying ses_G (3 LLM calls recorded)"
    assert out =~ "result: CLEAN — replay matches the recording"
    assert out =~ "replay session: ses_R"
  end

  test "diverged report shows call index and prompt tails" do
    findings = [
      %{class: :prompt_diverged, call_index: 7, recorded: String.duplicate("a", 500) <> "REC_TAIL",
        replayed: String.duplicate("b", 500) <> "REP_TAIL"},
      %{class: :extra_calls, detail: "agent required more LLM calls than the 12 recorded"}
    ]

    out =
      Check.format(%Report{golden_sid: "ses_G", replay_sid: "ses_R", recorded_calls: 12, findings: findings})

    assert out =~ "✕ call 8: prompt diverged"
    assert out =~ "REC_TAIL"
    assert out =~ "REP_TAIL"
    refute out =~ String.duplicate("a", 400)
    assert out =~ "✕ extra calls: agent required more LLM calls than the 12 recorded"
    assert out =~ "result: DIVERGED — 2 finding(s) across 12 recorded calls"
  end

  test "error formatting names the reason" do
    assert Check.format_error("ses_X", :not_found) =~ "not found"
    assert Check.format_error("ses_X", :not_replayable) =~ "re-record"
    assert Check.format_error("ses_X", {:chain_broken, {:broken_at, "ev_1"}}) =~ "chain"
  end
end
