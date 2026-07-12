defmodule Shem.Recall.ForkFromHitTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Shem.Recall
  alias Shem.REST.Handlers.Sessions

  @opts Sessions.init([])
  @parser_opts Plug.Parsers.init(parsers: [:json], json_decoder: Jason)

  setup do
    idx = start_supervised!({Shem.Recall.Index, name: :"recall_fork_#{:erlang.unique_integer([:positive])}"})
    %{index: idx}
  end

  test "a recall hit's fork pointer is accepted by the REST fork endpoint", %{index: idx} do
    # live session through the real EventLog (FakeStore) — no disk fixture,
    # so search reads it via the active-session path
    {:ok, sid} = Shem.EventLog.start_session()
    {:ok, _} = Shem.EventLog.append(sid, :agent_started, %{task: "recall fork loop test"})
    {:ok, _} = Shem.EventLog.append(sid, :llm_call_completed, %{content: "the forkable moment"})
    {:ok, _} = Shem.EventLog.append(sid, :agent_done, %{content: "done"})

    # FakeStore sessions have no dets file, so point the corpus at nothing and
    # go through context/4 directly for the pointer (search corpus is disk-based)
    {:ok, events} = Shem.EventLog.read_session_events(sid)
    target = Enum.find(events, &(&1.type == :agent_done))
    {:ok, ctx} = Recall.context(sid, target.id, 3, index: idx)
    assert %{fork_event_id: fork_id} = ctx.fork
    assert is_binary(fork_id)

    conn =
      conn(:post, "/#{sid}/fork", Jason.encode!(%{"fork_event_id" => fork_id}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(@parser_opts)
      |> Sessions.call(@opts)

    assert conn.status == 201
    assert %{"session_id" => new_sid} = Jason.decode!(conn.resp_body)
    assert new_sid != sid
  end
end
