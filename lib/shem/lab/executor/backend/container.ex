defmodule Shem.Lab.Executor.Backend.Container do
  @behaviour Shem.Lab.Executor.Backend

  @impl true
  def run_shell(cmd, timeout_ms, opts) do
    case Keyword.get(opts, :run_fn) do
      nil -> default_run(cmd, timeout_ms, opts)
      run_fn -> run_fn.(cmd, timeout_ms, opts)
    end
  end

  defp default_run(cmd, timeout_ms, opts) do
    bin = Keyword.get(opts, :runtime_bin, Application.get_env(:shem, :container_runtime_bin))

    if is_nil(bin) do
      {:error, "no container runtime available (tried podman, docker)"}
    else
      image =
        Keyword.get(opts, :image, Application.get_env(:shem, :executor_image, "debian:12-slim"))

      network =
        Keyword.get(opts, :network, Application.get_env(:shem, :executor_network, :default))

      args = build_args(image, network, cmd)

      task =
        Task.Supervisor.async_nolink(Shem.Lab.TaskSupervisor, fn ->
          System.cmd(bin, args, stderr_to_stdout: true)
        end)

      case Task.yield(task, timeout_ms) do
        {:ok, {output, 0}} ->
          {:ok, output}

        {:ok, {output, code}} ->
          {:error, "exit #{code}: #{output}"}

        {:exit, reason} ->
          {:error, "container process crashed: #{inspect(reason)}"}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, "timeout after #{timeout_ms}ms"}
      end
    end
  end

  defp build_args(image, network, cmd) do
    network_args =
      case network do
        :none -> ["--network=none"]
        :host -> ["--network=host"]
        _ -> []
      end

    ["run", "--rm", "-i"] ++ network_args ++ [image, "sh", "-c", cmd]
  end
end
