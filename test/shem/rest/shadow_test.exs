defmodule Shem.REST.ShadowTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Shem.REST.Router

  @opts Router.init([])

  setup do
    Shem.LLM.StubTransport.Server.reset()
    :ok
  end

  test "GET /agents/:id/shadow returns 404 for unknown agent" do
    conn = conn(:get, "/agents/no_such_agent_ever/shadow") |> Router.call(@opts)
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"] =~ "not found"
  end

  test "GET /agents/:id/shadow returns 404 when shadow_agent_enabled is false" do
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )
    config = %Shem.Agent.Config{task: "test task", system_prompt: "You are helpful."}
    agent_name = "rest_shadow_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Shem.AgentSupervisor.start_agent(
      agent_name, config, "ses_rest_#{System.unique_integer([:positive])}"
    )
    Process.sleep(50)

    conn = conn(:get, "/agents/#{agent_name}/shadow") |> Router.call(@opts)
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"] =~ "not found"
  end
end
