defmodule Shem.REST.AgentsTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Shem.REST.Router
  alias Shem.LLM.{StubTransport, Response}

  @opts Router.init([])

  setup do
    StubTransport.Server.reset()
    :ok
  end

  defp stub(content) do
    StubTransport.Server.push_response(
      {:ok, %Response{content: content, tokens_used: 5, model: :default, latency_ms: 1}}
    )
  end

  defp post_json(path, body) do
    encoded = Jason.encode!(body)
    conn(:post, path, encoded)
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp get_path(path) do
    conn(:get, path) |> Router.call(@opts)
  end

  defp delete_path(path) do
    conn(:delete, path) |> Router.call(@opts)
  end

  # POST /agents ──────────────────────────────────────────────────────────────

  test "POST /agents returns 400 when task is missing" do
    conn = post_json("/agents", %{preset: "general"})
    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"] =~ "task"
  end

  test "POST /agents returns 400 for unknown preset" do
    conn = post_json("/agents", %{preset: "nonexistent_preset_xyz", task: "do something"})
    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"] =~ "preset"
  end

  test "POST /agents starts an agent and returns agent_id and session_id" do
    stub("done")
    conn = post_json("/agents", %{preset: "general", task: "say hello"})
    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["agent_id"])
    assert is_binary(body["session_id"])
    Shem.Agent.stop(body["agent_id"])
  end

  # GET /agents/:id ────────────────────────────────────────────────────────────

  test "GET /agents/:id returns 404 for unknown agent" do
    conn = get_path("/agents/agent_DEADBEEF")
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "agent not found"
  end

  test "GET /agents/:id returns status for a running agent" do
    {:ok, agent_id} = Shem.Agent.start_with_preset("general", "pause")
    conn = get_path("/agents/#{agent_id}")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] in ["running", "done", "error"]
    Shem.Agent.stop(agent_id)
  end

  # GET /agents/:id/result ─────────────────────────────────────────────────────

  test "GET /agents/:id/result returns 404 for unknown agent" do
    conn = get_path("/agents/agent_DEADBEEF/result")
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "agent not found"
  end

  test "GET /agents/:id/result returns running when agent has not completed" do
    # Set a default response that triggers a tool call loop so the agent
    # stays in :running state for longer than the handler's 100ms await.
    # list_tools is a real builtin that always succeeds with no required args.
    # Use max_turns: 1_000_000 to prevent the agent finishing via turn limit.
    looping_response = %Response{
      content: ~s({"tool": "list_tools", "args": {}}),
      tokens_used: 1,
      model: :default,
      latency_ms: 1
    }
    StubTransport.Server.set_default({:ok, looping_response})

    {:ok, agent_id} = Shem.Agent.start(%Shem.Agent.Config{
      task: "wait",
      system_prompt: "test",
      max_turns: 1_000_000
    })
    conn = get_path("/agents/#{agent_id}/result")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "running"
    Shem.Agent.stop(agent_id)
  end

  test "GET /agents/:id/result returns done with content when agent completes" do
    stub("final answer")
    {:ok, agent_id} = Shem.Agent.start_with_preset("general", "answer me")
    assert {:ok, :done} = Shem.Agent.await(agent_id, 5_000)
    conn = get_path("/agents/#{agent_id}/result")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "done"
    assert is_binary(body["content"])
  end

  # GET /agents/:id/stream ────────────────────────────────────────────────────

  test "GET /agents/:id/stream returns 404 for unknown agent" do
    conn = get_path("/agents/no_such_agent/stream")
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] =~ "not found"
  end

  test "GET /agents/:id/stream streams SSE for running agent and receives stream_done" do
    stub("streamed answer")

    # Pre-generate session_id and register BEFORE starting the agent,
    # so we don't miss the stream_done broadcast.
    session_id = "ses_" <> Base.encode16(:crypto.strong_rand_bytes(8))
    agent_name = "agent_" <> Base.encode16(:crypto.strong_rand_bytes(4))

    Registry.register(Shem.StreamRegistry, session_id, nil)

    config = %Shem.Agent.Config{
      task: "sse test",
      system_prompt: "be helpful",
      max_turns: 1
    }
    {:ok, _pid} = Shem.AgentSupervisor.start_agent(agent_name, config, session_id)

    assert_receive {:stream_done, ^session_id}, 2_000
  end

  # DELETE /agents/:id ─────────────────────────────────────────────────────────

  test "DELETE /agents/:id returns 404 for unknown agent" do
    conn = delete_path("/agents/agent_DEADBEEF")
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "agent not found"
  end

  test "DELETE /agents/:id stops a running agent" do
    {:ok, agent_id} = Shem.Agent.start_with_preset("general", "work")
    conn = delete_path("/agents/#{agent_id}")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == true
  end
end
