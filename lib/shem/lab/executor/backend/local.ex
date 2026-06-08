defmodule Shem.Lab.Executor.Backend.Local do
  @behaviour Shem.Lab.Executor.Backend

  @impl true
  def run_shell(cmd, timeout_ms, _opts) do
    task =
      Task.Supervisor.async_nolink(Shem.Lab.TaskSupervisor, fn ->
        System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, code}} ->
        {:error, "exit #{code}: #{output}"}

      {:exit, reason} ->
        {:error, "shell command crashed: #{inspect(reason)}"}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, "timeout after #{timeout_ms}ms"}
    end
  end
end
