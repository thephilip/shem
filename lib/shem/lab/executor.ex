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
  Compiled ebin of the bundled stream_data dep — mounted into sandbox
  containers and `Code.prepend_path`-ed by the drivers so property tests need
  no `Mix.install` (no Hex, no network; works airgapped and in the portable
  tarball). Host fallback uses the same path directly: same BEAM, zero skew.
  """
  def stream_data_ebin, do: Application.app_dir(:stream_data, "ebin")

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
      # Per-run random marker: user code can't print it by accident or from
      # memory of the codebase. ponytail: not airtight — code sharing the
      # process can still read run.exs mid-run; irrelevant since the result
      # returns to the same agent that wrote the code.
      marker = "__SHEM_RESULT_#{Base.encode16(:crypto.strong_rand_bytes(8))}__"
      ebin = stream_data_ebin()
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "source.exs"), source)
      File.write!(Path.join(dir, "run.exs"), driver(marker, ebin))

      # run_code/execute_code is a scratch primitive with no granted profile —
      # deny network by default like every other unprofiled sandboxed tool.
      shell_opts =
        [image: Shem.Lab.Sandbox.image("elixir"), network: :none, mounts: [{dir, dir}, {ebin, ebin}]] ++
          Keyword.take(opts, [:run_fn])

      try do
        # cd to the dir's own absolute path (mounted at the same path in the
        # container) so the Local fallback backend runs the same command.
        case run_shell("cd #{dir} && #{elixir_invocation()} run.exs", timeout, shell_opts) do
          {:ok, out} ->
            # last occurrence: the driver prints the genuine marker after user
            # code returns, so anything earlier in the stream loses
            case String.split(out, marker) do
              [_] -> {:error, "no result marker in output: #{out}"}
              parts -> {:ok, parts |> List.last() |> String.trim()}
            end

          {:error, msg} ->
            {:error, msg}
        end
      after
        File.rm_rf!(dir)
      end
    end
  end

  defp driver(marker, ebin) do
    """
    Code.prepend_path(#{inspect(ebin)})
    mods = Code.compile_string(File.read!("source.exs"))
    {mod, _} = List.last(mods)
    IO.write("\\n#{marker}" <> inspect(mod.run()))
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
