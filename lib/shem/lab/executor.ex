defmodule Shem.Lab.Executor do
  @moduledoc """
  Sandboxed execution for agent-supplied code. Phase 6: the host-BEAM compile
  path (`run/3`) is gone — Elixir source runs in a container when a runtime is
  available, or a host `elixir` subprocess (AST-scanned) otherwise. Either way
  it never compiles into the host BEAM.
  """

  @default_timeout 30_000

  @doc "The resolved execution backend (process override, then config, then Local)."
  def backend do
    Process.get(:shem_executor_backend) ||
      Application.get_env(:shem, :resolved_executor_backend, Shem.Lab.Executor.Backend.Local)
  end

  @doc """
  How to invoke `elixir` for the resolved backend: a literal `elixir` inside a
  container (the image provides it), or the host launcher (system elixir, else
  the release's bundled runtime) on the Local backend. Append ` <script>.exs`.
  """
  def elixir_invocation do
    case backend() do
      Shem.Lab.Executor.Backend.Local ->
        {exe, prefix} = Shem.Lab.Languages.host_elixir()
        Enum.join([exe | prefix], " ")

      _ ->
        "elixir"
    end
  end

  @spec run_shell(String.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run_shell(cmd, timeout_ms, opts \\ []) do
    backend().run_shell(cmd, timeout_ms, opts)
  end

  @doc """
  Compile + run one-shot Elixir source in the sandbox and return the
  `inspect/1` of the last module's `run/0`, parsed from a sentinel line.
  """
  @spec run_source(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run_source(source, opts \\ []) do
    timeout =
      Keyword.get(opts, :timeout, Application.get_env(:shem, :executor_timeout_ms, @default_timeout))

    with :ok <- host_fallback_scan(source) do
      dir = Path.join(System.tmp_dir!(), "shem_run_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "source.exs"), source)
      File.write!(Path.join(dir, "run.exs"), driver())

      # run_code/execute_code is a scratch primitive with no granted profile —
      # deny network by default like every other unprofiled sandboxed tool.
      shell_opts =
        [image: Shem.Lab.Sandbox.image("elixir"), network: :none, mounts: [{dir, dir}]] ++
          Keyword.take(opts, [:run_fn])

      try do
        # cd to the dir's own absolute path (mounted at the same path in the
        # container) so the Local fallback backend runs the same command.
        case run_shell("cd #{dir} && #{elixir_invocation()} run.exs", timeout, shell_opts) do
          {:ok, out} ->
            case String.split(out, "__SHEM_RESULT__") do
              [_, result] -> {:ok, String.trim(result)}
              _ -> {:error, "no result marker in output: #{out}"}
            end

          {:error, msg} ->
            {:error, msg}
        end
      after
        File.rm_rf!(dir)
      end
    end
  end

  defp driver do
    """
    mods = Code.compile_string(File.read!("source.exs"))
    {mod, _} = List.last(mods)
    IO.write("\\n__SHEM_RESULT__" <> inspect(mod.run()))
    """
  end

  # In-container the sandbox is the enforcement layer; on the host-subprocess
  # fallback the AST scan is the only guard (spec §3).
  defp host_fallback_scan(source) do
    if backend() == Shem.Lab.Executor.Backend.Local do
      case Shem.Lab.SourceScan.scan(source) do
        :ok -> :ok
        {:error, msg} -> {:error, msg}
      end
    else
      :ok
    end
  end
end
