defmodule Shem.Replay.CheckTest do
  use ExUnit.Case, async: false

  alias Shem.Replay.Check
  alias Shem.LLM.{Request, Response}
  alias Shem.LLM.StubTransport.Server, as: StubServer

  @preset_name "replay_check_test_preset"

  setup do
    Shem.LLM.BudgetServer.reset()
    StubServer.reset()

    Shem.Agent.PresetStore.put(@preset_name, %{
      system_prompt: "V1 prompt: answer briefly.",
      tools: :all,
      max_turns: 5
    })

    on_exit(fn -> Shem.Agent.PresetStore.delete(@preset_name) end)
    :ok
  end

  # Record a golden by running a REAL agent against the stub transport.
  defp record_golden(task) do
    StubServer.set_default(
      {:ok, %Response{content: "all done", tokens_used: 1, model: :default, latency_ms: 1}}
    )

    {:ok, name, sid} = Shem.Agent.start_with_preset(@preset_name, task)
    assert {:ok, :done} = Shem.Agent.await(name, 10_000)
    sid
  end

  # Hand-craft a golden with full control over the recorded call queue.
  # (Prompts won't match the replay's real prompts — assert on class membership.)
  defp craft_golden(exchanges) do
    {:ok, sid} = Shem.EventLog.start_session()

    Shem.EventLog.append(sid, :agent_started, %{
      task: "crafted task",
      model: :default,
      max_turns: 20,
      preset: @preset_name,
      project_context: nil
    })

    Enum.each(exchanges, fn content ->
      StubServer.push_response(
        {:ok, %Response{content: content, tokens_used: 1, model: :default, latency_ms: 1}}
      )

      Shem.LLM.complete(%Request{prompt: "crafted", model: :default, session_id: sid})
    end)

    sid
  end

  # Like craft_golden/1, but the recorded exchange is a FAILED LLM call
  # (StubTransport returns {:error, reason}) instead of a content response.
  defp craft_golden_with_failure(reason) do
    {:ok, sid} = Shem.EventLog.start_session()

    Shem.EventLog.append(sid, :agent_started, %{
      task: "crafted task",
      model: :default,
      max_turns: 20,
      preset: @preset_name,
      project_context: nil
    })

    StubServer.push_response({:error, reason})
    Shem.LLM.complete(%Request{prompt: "crafted", model: :default, session_id: sid})

    sid
  end

  defp classes(report), do: report.findings |> Enum.map(& &1.class) |> Enum.uniq()

  test "clean replay: unchanged preset reproduces the recording" do
    sid = record_golden("clean replay test")

    assert {:ok, report} = Check.run(sid)
    assert Check.Report.clean?(report), inspect(report.findings)
    assert report.recorded_calls >= 1
    assert report.replay_sid != sid
  end

  test "a deliberate preset prompt change is caught as prompt_diverged with a call index" do
    sid = record_golden("prompt change test")

    Shem.Agent.PresetStore.put(@preset_name, %{
      system_prompt: "V2 prompt: CHANGED.",
      tools: :all,
      max_turns: 5
    })

    assert {:ok, report} = Check.run(sid)
    refute Check.Report.clean?(report)
    diverged = Enum.find(report.findings, &(&1.class == :prompt_diverged))
    assert diverged.call_index == 0
    assert diverged.recorded =~ "V1 prompt"
    assert diverged.replayed =~ "V2 prompt"
  end

  test "agent needing more calls than recorded reports extra_calls" do
    # One recorded call whose content is a tool call — the replayed agent
    # executes it and needs a second LLM call the recording doesn't have.
    sid = craft_golden([~s({"tool":"list_tools","args":{}})])

    assert {:ok, report} = Check.run(sid)
    assert :extra_calls in classes(report)
  end

  test "agent finishing early reports unused_calls" do
    sid = craft_golden(["all done", "never reached"])

    assert {:ok, report} = Check.run(sid)
    assert :unused_calls in classes(report)
    refute :extra_calls in classes(report)
  end

  test "a recorded failed LLM call replays as an agent error and reports replay_error" do
    sid = craft_golden_with_failure("boom")

    assert {:ok, report} = Check.run(sid)
    replay_error = Enum.find(report.findings, &(&1.class == :replay_error))
    assert replay_error, inspect(report.findings)
    assert is_binary(replay_error.detail)
  end

  test "unknown session is an error" do
    assert {:error, :not_found} = Check.run("ses_DOESNOTEXIST00")
  end

  test "session without agent_started is not an agent session" do
    {:ok, sid} = Shem.EventLog.start_session()

    StubServer.push_response(
      {:ok, %Response{content: "x", tokens_used: 1, model: :default, latency_ms: 1}}
    )

    Shem.LLM.complete(%Request{prompt: "p", model: :default, session_id: sid})
    assert {:error, :not_an_agent_session} = Check.run(sid)
  end

  test "pre-Phase-3 recording (no preset field) is not replayable" do
    {:ok, sid} = Shem.EventLog.start_session()
    Shem.EventLog.append(sid, :agent_started, %{task: "old", model: :default, max_turns: 20})

    StubServer.push_response(
      {:ok, %Response{content: "x", tokens_used: 1, model: :default, latency_ms: 1}}
    )

    Shem.LLM.complete(%Request{prompt: "p", model: :default, session_id: sid})
    assert {:error, :not_replayable} = Check.run(sid)
  end

  test "agent session with no LLM calls is an error" do
    {:ok, sid} = Shem.EventLog.start_session()

    Shem.EventLog.append(sid, :agent_started, %{
      task: "t", model: :default, max_turns: 20, preset: @preset_name, project_context: nil
    })

    assert {:error, :no_llm_events} = Check.run(sid)
  end
end
