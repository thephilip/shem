defmodule Shem.MCP.CounterfactualToolsTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Shem.EventLog
  alias Shem.MCP.Router
  alias Shem.LLM.{Response, StubTransport}

  @opts Router.init([])

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

  defp rpc(name, arguments) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments},
        "id" => 1
      })

    conn =
      conn(:post, "/message", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp call_tool(name, arguments) do
    resp = rpc(name, arguments)
    assert resp["error"] == nil, "unexpected MCP error: #{inspect(resp["error"])}"
    [%{"type" => "text", "text" => text}] = resp["result"]["content"]
    Jason.decode!(text)
  end

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

    {:ok, fork_ev} = EventLog.append(sid, :llm_call_completed, %{content: "I will use approach A"})
    {:ok, _} = EventLog.append(sid, :agent_turn_completed, %{turn: 1, outcome: :done})
    :ok = EventLog.finalize(sid)

    %{sid: sid, fork_ev: fork_ev}
  end

  defp poll_status(run_id, pred, n \\ 200)
  defp poll_status(_run_id, _pred, 0), do: flunk("status never matched")

  defp poll_status(run_id, pred, n) do
    st = call_tool("counterfactual_status", %{"run_id" => run_id})

    if pred.(st) do
      st
    else
      Process.sleep(50)
      poll_status(run_id, pred, n - 1)
    end
  end

  defp branch_status(st, sid),
    do: Enum.find(st["branches"], &(&1["session_id"] == sid))["status"]

  defp drive_to_done(branch_sid, content, n \\ 200)
  defp drive_to_done(_branch_sid, _content, 0), do: flunk("branch never awaited a turn")

  defp drive_to_done(branch_sid, content, n) do
    st = call_tool("agent_status", %{"agent_id" => branch_sid})

    case st["status"] do
      "awaiting_turn" ->
        call_tool("provide_turn", %{
          "agent_id" => branch_sid,
          "turn_token" => st["turn_token"],
          "content" => content
        })

        :ok

      "done" ->
        :ok

      _ ->
        Process.sleep(20)
        drive_to_done(branch_sid, content, n - 1)
    end
  end

  test "tools/list includes the three counterfactual tools with the side-effects warning" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "tools/list", "params" => %{}, "id" => 1})

    conn =
      conn(:post, "/message", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    tools = Jason.decode!(conn.resp_body)["result"]["tools"]
    names = Enum.map(tools, & &1["name"])
    for n <- ["counterfactual_run", "counterfactual_status", "counterfactual_select"] do
      assert n in names
    end

    run_desc = Enum.find(tools, &(&1["name"] == "counterfactual_run"))["description"]
    assert run_desc =~ "re-execute tools live"
  end

  test "run → poll → report → select round-trip (model brain, stubbed)" do
    %{sid: sid, fork_ev: fork_ev} = seed_parent(:model)
    stub("variant one outcome")
    stub("variant two outcome")

    run =
      call_tool("counterfactual_run", %{
        "session_id" => sid,
        "fork_event_id" => fork_ev.id,
        "variants" => ["premise one", "premise two"]
      })

    assert run["side_effects"] == "variants re-execute tools live"
    assert [%{"session_id" => b0}, %{"session_id" => b1}] = run["branches"]

    st = poll_status(run["run_id"], &(&1["status"] == "complete"))
    assert branch_status(st, b0) == "done"
    assert branch_status(st, b1) == "done"
    assert st["report"]["digest"] =~ ~r/^[0-9a-f]{64}$/
    assert length(st["report"]["branches"]) == 2

    stub("continued after selection")
    sel = call_tool("counterfactual_select", %{"run_id" => run["run_id"], "branch_session_id" => b0})
    assert sel["session_id"] == b0

    {:ok, pevents} = EventLog.read_session_events(sid)
    types = Enum.map(pevents, & &1.type)
    assert :counterfactual_run in types
    assert :counterfactual_completed in types
    assert :counterfactual_selected in types

    if sel["agent_id"], do: Shem.Agent.stop(sel["agent_id"])
  end

  test "client-brain exit criterion: run, steer each branch via provide_turn, report, select" do
    %{sid: sid, fork_ev: fork_ev} = seed_parent(:client)

    run =
      call_tool("counterfactual_run", %{
        "session_id" => sid,
        "fork_event_id" => fork_ev.id,
        "variants" => ["what if approach B", "what if approach C"]
      })

    [%{"session_id" => b0}, %{"session_id" => b1}] = run["branches"]

    # sequential: branch 0 parks first — the MCP caller IS the brain
    :ok = drive_to_done(b0, "B looked better: done")
    :ok = drive_to_done(b1, "C hit a wall: done")

    st = poll_status(run["run_id"], &(&1["status"] == "complete"))
    assert branch_status(st, b0) == "done"
    assert branch_status(st, b1) == "done"
    assert st["report"] != nil

    sel =
      call_tool("counterfactual_select", %{
        "run_id" => run["run_id"],
        "branch_session_id" => b0
      })

    assert sel["session_id"] == b0

    # ALL branches remain in the log, and every chain verifies
    for s <- [sid, b0, b1] do
      {:ok, events} = EventLog.read_session_events(s)
      assert events != []
      assert {:ok, _, _} = EventLog.verify_chain(s)
    end

    # the selected client-brain branch is live again for the caller to steer
    if sel["agent_id"], do: Shem.Agent.stop(sel["agent_id"])
  end

  test "error mapping: bad session, too many variants" do
    resp =
      rpc("counterfactual_run", %{
        "session_id" => "ses_MISSING",
        "fork_event_id" => "evt_x",
        "variants" => ["v"]
      })

    assert %{"error" => %{"code" => -32602}} = resp

    %{sid: sid, fork_ev: fork_ev} = seed_parent(:model)

    resp2 =
      rpc("counterfactual_run", %{
        "session_id" => sid,
        "fork_event_id" => fork_ev.id,
        "variants" => ["1", "2", "3", "4", "5"]
      })

    assert %{"error" => %{"code" => -32602, "message" => msg}} = resp2
    assert msg =~ "variant"

    resp3 = rpc("counterfactual_status", %{"run_id" => "nope"})
    assert %{"error" => %{"code" => -32602}} = resp3
  end
end
