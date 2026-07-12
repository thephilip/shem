defmodule Shem.CounterfactualTest do
  use ExUnit.Case, async: false

  alias Shem.Counterfactual
  alias Shem.EventLog
  alias Shem.LLM.{Response, StubTransport}

  setup do
    Shem.LLM.BudgetServer.reset()
    StubTransport.Server.reset()
    :ok
  end

  defp stub(content) do
    StubTransport.Server.push_response(
      {:ok, %Response{content: content, tokens_used: 5, model: :default, latency_ms: 1}}
    )
  end

  # A parent session shaped like a real agent's log: agent_started (records
  # brain), a checkpoint at the start of the turn (full Config — what resume
  # reconstruction folds from), then the turn's llm_call_completed (fork point).
  defp seed_parent(brain) do
    {:ok, sid} = EventLog.start_session()

    config = %Shem.Agent.Config{
      task: "pick an approach",
      system_prompt: "You are a test agent.",
      tools: [],
      max_turns: 20,
      brain: brain,
      preset: "general"
    }

    {:ok, _} =
      EventLog.append(sid, :agent_started, %{
        task: "pick an approach",
        model: :default,
        max_turns: 20,
        preset: "general",
        brain: brain,
        project_context: nil
      })

    {:ok, _} =
      EventLog.append(sid, :agent_checkpoint, %{
        history: [%{role: :user, content: "pick an approach"}],
        turn_count: 0,
        config: config,
        node: node()
      })

    {:ok, _} = EventLog.append(sid, :agent_turn_started, %{turn: 1})
    {:ok, fork_ev} = EventLog.append(sid, :llm_call_completed, %{content: "I will use approach A"})
    {:ok, _} = EventLog.append(sid, :agent_turn_completed, %{turn: 1, outcome: :done})
    {:ok, tool_ev} = EventLog.append(sid, :agent_tool_called, %{tool: "diff_text", args: %{}})
    :ok = EventLog.finalize(sid)

    %{sid: sid, fork_ev: fork_ev, tool_ev: tool_ev}
  end

  defp await_run(run_id, n \\ 200)
  defp await_run(_run_id, 0), do: flunk("run never completed")

  defp await_run(run_id, n) do
    {:ok, st} = Counterfactual.status(run_id)

    if st.status == "complete" do
      st
    else
      Process.sleep(50)
      await_run(run_id, n - 1)
    end
  end

  test "full sequential run: 2 variants complete, report + chained run record" do
    %{sid: sid, fork_ev: fork_ev} = seed_parent(:model)
    stub("variant one outcome")
    stub("variant two outcome")

    {:ok, res} =
      Counterfactual.run(sid, fork_ev.id, ["premise one", "premise two"])

    assert res.status == "running"
    assert [%{session_id: b0, premise_digest: d0}, %{session_id: b1, premise_digest: d1}] =
             res.branches

    assert d0 =~ ~r/^[0-9a-f]{64}$/
    assert d0 != d1

    st = await_run(res.run_id)
    assert st.coordinator == "live"
    assert Enum.map(st.branches, & &1.status) == ["done", "done"]
    assert st.report != nil

    # parent contains the run lifecycle events and is finalized again
    {:ok, pevents} = EventLog.read_session_events(sid)
    run_ev = Enum.find(pevents, &(&1.type == :counterfactual_run))
    completed = Enum.find(pevents, &(&1.type == :counterfactual_completed))
    assert run_ev.payload.branch_session_ids == [b0, b1]
    assert completed.payload.report_digest == st.report.digest
    assert {:error, :session_ended} = EventLog.append(sid, :junk, %{})

    # branch sessions hold the full premises (parent only digests)
    {:ok, b0_events} = EventLog.read_session_events(b0)
    assert Enum.any?(b0_events, &(&1.type == :llm_call_completed and &1.payload[:content] == "premise one"))
  end

  test "max_variants exceeded → error" do
    %{sid: sid, fork_ev: fork_ev} = seed_parent(:model)
    too_many = for i <- 1..5, do: "v#{i}"
    assert {:error, :too_many_variants} = Counterfactual.run(sid, fork_ev.id, too_many)
    assert {:error, :invalid_variants} = Counterfactual.run(sid, fork_ev.id, [])
    assert {:error, :invalid_variants} = Counterfactual.run(sid, fork_ev.id, ["ok", ""])
  end

  test "a non-llm fork target resolves to the earlier llm event" do
    %{sid: sid, fork_ev: fork_ev, tool_ev: tool_ev} = seed_parent(:model)
    stub("resolved variant outcome")

    {:ok, res} = Counterfactual.run(sid, tool_ev.id, ["alt"])
    await_run(res.run_id)

    {:ok, pevents} = EventLog.read_session_events(sid)
    run_ev = Enum.find(pevents, &(&1.type == :counterfactual_run))
    assert run_ev.payload.fork_event_id == fork_ev.id
  end

  test "select rejects a session that is not a branch of the run" do
    %{sid: sid, fork_ev: fork_ev} = seed_parent(:model)
    stub("outcome")
    {:ok, res} = Counterfactual.run(sid, fork_ev.id, ["alt"])
    await_run(res.run_id)

    assert {:error, :not_in_run} = Counterfactual.select(res.run_id, sid)
    assert {:error, :not_found} = Counterfactual.select("ses_nope:evt_nope", sid)
  end

  test "select appends selection evidence and returns the winner's coordinates" do
    %{sid: sid, fork_ev: fork_ev} = seed_parent(:model)
    stub("variant outcome")
    {:ok, res} = Counterfactual.run(sid, fork_ev.id, ["the winning premise"])
    st = await_run(res.run_id)
    [%{session_id: winner}] = res.branches

    # the selected branch is resumed — it will make one more (stubbed) call
    stub("continued after selection")

    assert {:ok, out} = Counterfactual.select(res.run_id, winner)
    assert out.session_id == winner
    assert is_binary(out.fork_event_id)

    {:ok, pevents} = EventLog.read_session_events(sid)
    sel = Enum.find(pevents, &(&1.type == :counterfactual_selected))
    assert sel.payload.selected_session_id == winner
    assert sel.payload.report_digest == st.report.digest
    # parent refinalized after the selection append
    assert {:error, :session_ended} = EventLog.append(sid, :junk, %{})

    if out.agent_id, do: Shem.Agent.stop(out.agent_id)
  end

  test "status reconstructs from the parent log when the coordinator is dead" do
    # client-brain parent → the variant parks awaiting a turn, coordinator stays live
    %{sid: sid, fork_ev: fork_ev} = seed_parent(:client)
    {:ok, res} = Counterfactual.run(sid, fork_ev.id, ["parked premise"])

    [{pid, _}] = Registry.lookup(Shem.Counterfactual.Registry, res.run_id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    {:ok, st} = Counterfactual.status(res.run_id)
    assert st.coordinator == "not_live"
    assert Enum.map(st.branches, & &1.session_id) == Enum.map(res.branches, & &1.session_id)

    # cleanup: stop the orphaned branch agent if it's still around
    [%{session_id: bsid}] = res.branches

    case Shem.MCP.Handlers.AgentCommon.find_by_session(bsid) do
      {:ok, name} -> Shem.Agent.stop(name)
      _ -> :ok
    end
  end
end
