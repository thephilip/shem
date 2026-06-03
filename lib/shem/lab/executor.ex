defmodule Shem.Lab.Executor do
  @default_timeout 5_000

  @spec run(String.t(), (atom() -> any()), keyword()) ::
          {:ok, any()}
          | {:error, :compile, String.t()}
          | {:error, :timeout}
          | {:error, :runtime, any()}
  def run(source, fun, opts \\ []) do
    timeout =
      Keyword.get(opts, :timeout, Application.get_env(:shem, :executor_timeout_ms, @default_timeout))

    case compile(source) do
      {:ok, modules} ->
        Enum.each(modules, fn {mod, bc} -> :code.load_binary(mod, ~c"nofile", bc) end)
        last_module = modules |> List.last() |> elem(0)

        try do
          execute(last_module, fun, timeout)
        after
          Enum.each(modules, fn {mod, _} ->
            :code.purge(mod)
            :code.delete(mod)
          end)
        end

      error ->
        error
    end
  end

  defp compile(source) do
    try do
      case Code.compile_string(source) do
        [] -> {:error, :compile, "source defines no modules"}
        modules -> {:ok, modules}
      end
    rescue
      e -> {:error, :compile, Exception.message(e)}
    end
  end

  defp execute(module, fun, timeout) do
    task = Task.Supervisor.async_nolink(Shem.Lab.TaskSupervisor, fn -> fun.(module) end)

    case Task.yield(task, timeout) do
      {:ok, value} ->
        {:ok, value}

      {:exit, reason} ->
        {:error, :runtime, reason}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end
end
