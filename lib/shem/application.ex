defmodule Shem.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Horde.Registry, [name: Shem.Registry, keys: :unique, members: :auto]},
        Shem.AgentSupervisor,
        Shem.EventLog,
        Shem.Trust.Store,
        {Task.Supervisor, name: Shem.Lab.TaskSupervisor},
        Shem.Lab.Registry,
        Shem.LLM.BudgetServer
      ] ++
        adversarial_children() ++
        llm_stub_children() ++
        mcp_children() ++
        cluster_children() ++
        tui_children()

    opts = [strategy: :one_for_one, name: Shem.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @test_env Mix.env() == :test

  defp adversarial_children do
    if Application.get_env(:shem, :start_adversarial, true) do
      [Shem.Adversarial.Supervisor]
    else
      []
    end
  end

  defp llm_stub_children do
    if Application.get_env(:shem, :start_llm_stub, @test_env) do
      [{Shem.LLM.StubTransport.Server, name: Shem.LLM.StubTransport.Server}]
    else
      []
    end
  end

  defp mcp_children do
    if Application.get_env(:shem, :start_mcp, true) do
      [Shem.MCP.Server, Shem.MCP.Client.Supervisor]
    else
      []
    end
  end

  defp cluster_children do
    if Application.get_env(:shem, :start_cluster, true) do
      [
        {Cluster.Supervisor,
         [Application.get_env(:libcluster, :topologies, []), [name: Shem.Cluster.Supervisor]]},
        Shem.Cluster
      ]
    else
      []
    end
  end

  defp tui_children do
    if Application.get_env(:shem, :start_tui, true) do
      [Shem.TUI.RuntimeSupervisor]
    else
      []
    end
  end
end
