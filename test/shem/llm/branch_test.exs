defmodule Shem.LLM.BranchTest do
  use ExUnit.Case, async: false

  alias Shem.LLM
  alias Shem.LLM.{Request, Response, Branch}
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

  defp nth_completed_event(sid, n) do
    {:ok, events} = Shem.EventLog.events(sid)
    events |> Enum.filter(&(&1.type == :llm_call_completed)) |> Enum.at(n)
  end

  setup do
    Shem.LLM.BudgetServer.reset()
    StubServer.reset()
    :ok
  end

  describe "branch_at/4 — happy path" do
    test "returns {:ok, branch_sid, result}" do
      original_sid = record_session([{"q1", "a1", 5}])
      fork_event = nth_completed_event(original_sid, 0)

      assert {:ok, branch_sid, :done} =
               Branch.branch_at(original_sid, fork_event.id, [], fn _sid -> :done end)

      assert String.starts_with?(branch_sid, "ses_")
      assert branch_sid != original_sid
    end

    test "prefix call is served from recording" do
      original_sid = record_session([{"q1", "a1", 5}, {"q2", "a2", 3}])
      fork_event = nth_completed_event(original_sid, 0)

      {:ok, _branch_sid, response} =
        Branch.branch_at(
          original_sid,
          fork_event.id,
          [%{content: "alt answer", tokens_used: 7}],
          fn branch_sid ->
            LLM.complete(%Request{prompt: "q1", model: :default, session_id: branch_sid})
          end
        )

      assert {:ok, %Response{content: "a1"}} = response
    end

    test "alt queue is served after the fork" do
      original_sid = record_session([{"q1", "a1", 5}])
      fork_event = nth_completed_event(original_sid, 0)

      {:ok, _branch_sid, response} =
        Branch.branch_at(
          original_sid,
          fork_event.id,
          [%{content: "alt answer", tokens_used: 7}],
          fn branch_sid ->
            LLM.complete(%Request{prompt: "q1", model: :default, session_id: branch_sid})
            LLM.complete(%Request{prompt: "q2", model: :default, session_id: branch_sid})
          end
        )

      assert {:ok, %Response{content: "alt answer"}} = response
    end

    test "fork before all LLM calls yields empty prefix — full alt queue used" do
      original_sid = record_session([{"q1", "a1", 5}])
      {:ok, events} = Shem.EventLog.events(original_sid)
      first_event = hd(events)

      {:ok, _branch_sid, response} =
        Branch.branch_at(
          original_sid,
          first_event.id,
          [%{content: "synthetic", tokens_used: 2}],
          fn branch_sid ->
            LLM.complete(%Request{prompt: "q1", model: :default, session_id: branch_sid})
          end
        )

      assert {:ok, %Response{content: "synthetic"}} = response
    end

    test "branch session contains :branch_created event with correct provenance" do
      original_sid = record_session([{"q1", "a1", 5}])
      fork_event = nth_completed_event(original_sid, 0)

      {:ok, branch_sid, _} =
        Branch.branch_at(
          original_sid,
          fork_event.id,
          [%{content: "x", tokens_used: 1}],
          fn _sid -> :ok end
        )

      {:ok, events} = Shem.EventLog.events(branch_sid)
      created = Enum.find(events, &(&1.type == :branch_created))
      assert created.payload.original_session_id == original_sid
      assert created.payload.fork_event_id == fork_event.id
      assert created.payload.alt_count == 1
    end

    test "process dict is cleaned up after branch_at" do
      original_sid = record_session([{"q", "a", 1}])
      fork_event = nth_completed_event(original_sid, 0)
      Branch.branch_at(original_sid, fork_event.id, [], fn _sid -> :ok end)
      assert Process.get(:shem_replay_pipeline) == nil
    end

    test "process dict cleaned up when fun raises" do
      original_sid = record_session([{"q", "a", 1}])
      fork_event = nth_completed_event(original_sid, 0)

      assert_raise RuntimeError, fn ->
        Branch.branch_at(original_sid, fork_event.id, [], fn _sid -> raise "boom" end)
      end

      assert Process.get(:shem_replay_pipeline) == nil
    end
  end

  describe "branch_at/4 — error cases" do
    test "{:error, :session_not_found} for unknown session" do
      assert {:error, :session_not_found} =
               Branch.branch_at("ses_unknown00", "evt_x", [], fn _sid -> :ok end)
    end

    test "{:error, :no_llm_events} for session with no LLM calls" do
      {:ok, sid} = Shem.EventLog.start_session()

      assert {:error, :no_llm_events} =
               Branch.branch_at(sid, "evt_x", [], fn _sid -> :ok end)
    end

    test "{:error, :fork_event_not_found} for unknown event ID" do
      original_sid = record_session([{"q", "a", 1}])

      assert {:error, :fork_event_not_found} =
               Branch.branch_at(original_sid, "evt_nonexistent", [], fn _sid -> :ok end)
    end
  end
end
