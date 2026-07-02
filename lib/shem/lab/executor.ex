defmodule Shem.Lab.Executor do
  @default_timeout 5_000

  @spec run(String.t(), (atom() -> any()), keyword()) ::
          {:ok, any()}
          | {:error, :compile, String.t()}
          | {:error, :timeout}
          | {:error, :runtime, any()}
          | {:error, any()}
  def run(source, fun, opts \\ []) do
    timeout =
      Keyword.get(opts, :timeout, Application.get_env(:shem, :executor_timeout_ms, @default_timeout))

    target_node = Keyword.get(opts, :node, nil)
    scan? = Keyword.get(opts, :scan, true)

    with :ok <- maybe_scan(source, scan?) do
      if target_node && target_node != Node.self() do
        run_remote(source, fun, timeout, target_node)
      else
        run_local(source, fun, timeout)
      end
    end
  end

  # ponytail: scan failures reuse the :compile error channel — every caller
  # already handles {:error, :compile, msg}; the "safety scan:" prefix keeps
  # them distinguishable.
  defp maybe_scan(_source, false), do: :ok

  defp maybe_scan(source, true) do
    case Shem.Lab.SourceScan.scan(source) do
      :ok -> :ok
      {:error, msg} -> {:error, :compile, msg}
    end
  end

  @spec run_shell(String.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run_shell(cmd, timeout_ms, opts \\ []) do
    backend =
      Process.get(:shem_executor_backend) ||
        Application.get_env(:shem, :resolved_executor_backend, Shem.Lab.Executor.Backend.Local)

    backend.run_shell(cmd, timeout_ms, opts)
  end

  defp run_remote(source, fun, timeout, node) do
    case :rpc.call(node, __MODULE__, :run, [source, fun, [timeout: timeout]], timeout + 1_000) do
      {:badrpc, reason} -> {:error, reason}
      result -> result
    end
  end

  defp run_local(source, fun, timeout) do
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
