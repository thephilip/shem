defmodule Shem.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    resolve_executor_backend()

    children =
      [
        {Horde.Registry, [name: Shem.Registry, keys: :unique, members: :auto]},
        Shem.AgentSupervisor,
        Shem.EventLog,
        Shem.Trust.Store,
        Shem.Agent.PresetStore,
        Shem.LLM.Router,
        {Task.Supervisor, name: Shem.Lab.TaskSupervisor},
        Shem.Lab.Registry,
        Shem.LLM.BudgetServer,
        {Registry, keys: :duplicate, name: Shem.StreamRegistry}
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

  def resolve_executor_backend(detect_fn \\ &detect_container_runtime/0) do
    case Application.get_env(:shem, :executor_backend, :auto) do
      :local ->
        Application.put_env(:shem, :resolved_executor_backend, Shem.Lab.Executor.Backend.Local)
        Application.put_env(:shem, :container_runtime_bin, nil)

      :container ->
        runtime = detect_fn.()

        if is_nil(runtime) do
          Logger.error(
            "Shem: no container runtime found (tried podman, docker). " <>
              "Shell tool will return errors until a container runtime is installed."
          )
        end

        Application.put_env(:shem, :resolved_executor_backend, Shem.Lab.Executor.Backend.Container)
        Application.put_env(:shem, :container_runtime_bin, runtime)

      :auto ->
        case detect_fn.() do
          nil ->
            Logger.warning(
              "Shem: no container runtime found (tried podman, docker). " <>
                "Shell tool will run without isolation. " <>
                "Install podman or docker to enable sandboxed execution."
            )

            Application.put_env(:shem, :resolved_executor_backend, Shem.Lab.Executor.Backend.Local)
            Application.put_env(:shem, :container_runtime_bin, nil)

          runtime ->
            Application.put_env(
              :shem,
              :resolved_executor_backend,
              Shem.Lab.Executor.Backend.Container
            )

            Application.put_env(:shem, :container_runtime_bin, runtime)
        end
    end
  end

  defp detect_container_runtime do
    cond do
      System.find_executable("podman") != nil -> "podman"
      System.find_executable("docker") != nil -> "docker"
      true -> nil
    end
  end
end
