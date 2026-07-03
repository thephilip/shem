defmodule Shem.LLM.ReplayTest do
  use ExUnit.Case, async: false

  alias Shem.LLM
  alias Shem.LLM.{Request, Response, Replay}
  alias Shem.LLM.StubTransport.Server, as: StubServer

  defp record_session(exchanges) do
    {:ok, sid} = Shem.EventLog.start_session()

    Enum.each(exchanges, fn {prompt, content, tokens} ->
      StubServer.push_response(
        {:ok, %Response{content: content, tokens_used: tokens, model: :default, latency_ms: 1}}
      )

      LLM.complete(%Request{prompt: prompt, model: :default, session_id: sid})
    end)

    sid
  end

  setup do
    Shem.LLM.BudgetServer.reset()
    Shem.LLM.StubTransport.Server.reset()
    :ok
  end

  describe "with_replay/2 — happy path" do
    test "returns {:ok, replay_session_id, result}" do
      original_sid = record_session([{"what is BEAM?", "a runtime", 5}])

      assert {:ok, replay_sid, :agent_done} =
               Replay.with_replay(original_sid, fn _sid -> :agent_done end)

      assert String.starts_with?(replay_sid, "ses_")
      assert replay_sid != original_sid
    end

    test "LLM calls inside fun receive recorded responses" do
      original_sid = record_session([{"ask", "the answer", 10}])

      {:ok, _replay_sid, response} =
        Replay.with_replay(original_sid, fn replay_sid ->
          LLM.complete(%Request{prompt: "ask", model: :default, session_id: replay_sid})
        end)

      assert {:ok, %Response{content: "the answer"}} = response
    end

    test "replay session event log contains :llm_call_started and :llm_call_completed" do
      original_sid = record_session([{"prompt", "content", 3}])

      {:ok, replay_sid, _} =
        Replay.with_replay(original_sid, fn replay_sid ->
          LLM.complete(%Request{prompt: "prompt", model: :default, session_id: replay_sid})
        end)

      {:ok, events} = Shem.EventLog.events(replay_sid)
      types = Enum.map(events, & &1.type)
      assert :llm_call_started in types
      assert :llm_call_completed in types
    end

    test "process dict is cleaned up after with_replay" do
      original_sid = record_session([{"q", "a", 1}])
      Replay.with_replay(original_sid, fn _sid -> :ok end)
      assert Process.get(:shem_replay_pipeline) == nil
    end
  end

  describe "with_replay/2 — divergence" do
    test "returns result despite prompt divergence" do
      original_sid = record_session([{"original prompt", "recorded answer", 5}])

      {:ok, replay_sid, response} =
        Replay.with_replay(original_sid, fn replay_sid ->
          LLM.complete(%Request{prompt: "different prompt", model: :default, session_id: replay_sid})
        end)

      assert {:ok, %Response{content: "recorded answer"}} = response

      {:ok, events} = Shem.EventLog.events(replay_sid)
      assert Enum.any?(events, &(&1.type == :llm_call_diverged))
    end
  end

  describe "with_replay/2 — exhaustion" do
    test "returns fun result containing {:error, :replay_exhausted}" do
      original_sid = record_session([{"q1", "a1", 5}])

      {:ok, replay_sid, result} =
        Replay.with_replay(original_sid, fn replay_sid ->
          LLM.complete(%Request{prompt: "q1", model: :default, session_id: replay_sid})
          LLM.complete(%Request{prompt: "q2", model: :default, session_id: replay_sid})
        end)

      assert {:error, :replay_exhausted} = result

      {:ok, events} = Shem.EventLog.events(replay_sid)
      assert Enum.any?(events, &(&1.type == :replay_exhausted))
    end
  end

  describe "with_replay/2 — error cases" do
    test "returns {:error, :not_found} for unknown session" do
      # with_replay reads via read_session_events (so historical, non-active
      # goldens replay); its missing-session error atom is :not_found.
      assert {:error, :not_found} =
               Replay.with_replay("ses_doesnotexist00", fn _sid -> :ok end)
    end

    test "returns {:error, :no_llm_events} for session with no LLM calls" do
      {:ok, sid} = Shem.EventLog.start_session()
      assert {:error, :no_llm_events} =
               Replay.with_replay(sid, fn _sid -> :ok end)
    end

    test "process dict cleaned up even when fun raises" do
      original_sid = record_session([{"q", "a", 1}])

      assert_raise RuntimeError, fn ->
        Replay.with_replay(original_sid, fn _sid -> raise "boom" end)
      end

      assert Process.get(:shem_replay_pipeline) == nil
    end
  end

  describe "diff/2" do
    test "returns [] for identical replay" do
      original_sid = record_session([{"q1", "a1", 5}, {"q2", "a2", 3}])

      {:ok, replay_sid, _} =
        Replay.with_replay(original_sid, fn replay_sid ->
          LLM.complete(%Request{prompt: "q1", model: :default, session_id: replay_sid})
          LLM.complete(%Request{prompt: "q2", model: :default, session_id: replay_sid})
        end)

      assert [] = Replay.diff(original_sid, replay_sid)
    end

    test "returns diff entry for prompt divergence" do
      original_sid = record_session([{"original", "answer", 5}])

      {:ok, replay_sid, _} =
        Replay.with_replay(original_sid, fn replay_sid ->
          LLM.complete(%Request{prompt: "changed", model: :default, session_id: replay_sid})
        end)

      diffs = Replay.diff(original_sid, replay_sid)
      assert length(diffs) == 1
      assert hd(diffs).type == :prompt_diverged
      assert hd(diffs).call_index == 0
    end

    test "returns :missing_in_replay when replay made fewer calls" do
      original_sid = record_session([{"q1", "a1", 5}, {"q2", "a2", 3}])

      {:ok, replay_sid, _} =
        Replay.with_replay(original_sid, fn replay_sid ->
          LLM.complete(%Request{prompt: "q1", model: :default, session_id: replay_sid})
        end)

      diffs = Replay.diff(original_sid, replay_sid)
      assert Enum.any?(diffs, &(&1.type == :missing_in_replay))
    end
  end
end
