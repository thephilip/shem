defmodule Shem.Lab.GraduationGate.Elixir do
  @moduledoc """
  Containerized graduation for Elixir tools (Phase 6): tool + test compile and
  run inside the sandbox, never the host BEAM. SourceScan stays as a fast
  pre-filter. See docs/superpowers/specs/2026-07-10-elixir-parity-sandbox-design.md.
  """

  alias Shem.Lab.{Executor, Registry, Workspace}
  alias Shem.Tool

  def run(source, test_source, opts) do
    combined = source <> "\n" <> test_source

    with {:ok, module} <- extract_module(source),
         :ok <- scan(combined) do
      gate(combined, module, source, test_source, opts)
    end
  end

  defp scan(combined) do
    case Shem.Lab.SourceScan.scan(combined) do
      :ok ->
        :ok

      {:error, msg} ->
        {:ok, _} = Shem.EventLog.start_session("security")
        Shem.EventLog.append("security", :scan_rejected, %{reason: msg})
        {:error, :compile, msg}
    end
  end

  defp gate(combined, module, source, test_source, opts) do
    property? = property_tested?(test_source)

    dir = Path.join(System.tmp_dir!(), "shem_grad_#{System.unique_integer([:positive])}")
    # per-run random marker so test code can't forge a "compile error" verdict
    # by printing the sentinel (same scheme as Executor.run_source)
    marker = "__SHEM_COMPILE_ERROR_#{Base.encode16(:crypto.strong_rand_bytes(8))}__"
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "combined.exs"), combined)
    File.write!(Path.join(dir, "gate.exs"), gate_driver(property?, marker))

    granted = Keyword.get(opts, :sandbox) || %{}
    image = granted["image"] || Shem.Lab.Sandbox.image("elixir")
    timeout = Application.get_env(:shem, :executor_timeout_ms, 60_000)

    extra_mounts =
      for m <- granted["mounts"] || [],
          do: {Path.expand(m["host"]), m["container"], Map.get(m, "mode", "ro")}

    # cd to the dir's own absolute path (mounted at the same path) so the
    # Local fallback backend runs the identical command.
    result =
      Executor.run_shell("cd #{dir} && #{Executor.elixir_invocation()} gate.exs", timeout,
        image: image,
        mounts: [{dir, dir} | extra_mounts]
      )

    File.rm_rf!(dir)

    case result do
      {:ok, _} ->
        build(source, test_source, module, property?, opts)

      {:error, "timeout" <> _} ->
        {:error, :timeout}

      {:error, reason} ->
        case String.split(reason, marker) do
          [_, msg] -> {:error, :compile, String.trim(msg)}
          _ -> {:error, :gate, reason}
        end
    end
  end

  # The test module is last in the combined source; its run/0 raising fails
  # the script (non-zero exit) — today's test contract, unchanged.
  defp gate_driver(property?, marker) do
    install = if property?, do: "Mix.install([:stream_data])\n", else: ""

    install <>
      """
      mods =
        try do
          Code.compile_string(File.read!("combined.exs"))
        rescue
          e ->
            IO.puts("#{marker} " <> Exception.message(e))
            System.halt(2)
        end

      {mod, _} = List.last(mods)

      # Test contract: run/0 returns :ok on success (matches the pre-Phase-6
      # {:ok, :ok} gate). A non-raising failure value must still fail the gate.
      case mod.run() do
        :ok -> :ok
        other -> IO.puts("gate test returned " <> inspect(other)); System.halt(3)
      end
      """
  end

  defp build(source, test_source, module, property?, opts) do
    id = unique_id(module)

    tool = %Tool{
      id: id,
      name: module |> Atom.to_string() |> String.split(".") |> List.last(),
      runtime: {:port, Workspace.runtime_path(id, "elixir")},
      source: source,
      test_source: test_source,
      constraints: Keyword.get(opts, :constraints, []),
      graduated_at: DateTime.utc_now(),
      metadata: %{
        :property_tested => property?,
        "language" => "elixir",
        "description" => Keyword.get(opts, :description, ""),
        "schema" => Keyword.get(opts, :schema, %{}),
        "actions" => Keyword.get(opts, :actions) || []
      }
    }

    Shem.Lab.GraduationGate.Common.register_and_seed(tool, not property?)
  end

  def extract_module(source) do
    case Regex.run(~r/defmodule\s+(\S+)\s+do/, source) do
      [_, name] -> {:ok, Module.concat([name])}
      _ -> {:error, :compile, "could not determine module name from source"}
    end
  end

  # Cheap half of the property check: StreamData presence. The substantive
  # half is that the property must PASS inside the sandbox like any test.
  def property_tested?(test_source), do: test_source =~ ~r/check_all|StreamData\./

  defp unique_id(module) do
    base =
      module
      |> Atom.to_string()
      |> String.split(".")
      |> List.last()
      |> Macro.underscore()

    if Registry.lookup(base) == {:error, :not_found} do
      base
    else
      version =
        Enum.find(2..100, fn v ->
          Registry.lookup("#{base}_v#{v}") == {:error, :not_found}
        end)

      "#{base}_v#{version}"
    end
  end
end
