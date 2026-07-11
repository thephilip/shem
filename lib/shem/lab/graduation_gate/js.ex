defmodule Shem.Lab.GraduationGate.JS do
  alias Shem.Lab.{Workspace, Executor}
  alias Shem.Tool

  def run(source, test_source, opts) do
    id = unique_id(source)
    tmp = Path.join(System.tmp_dir!(), "shem_grad_js_#{id}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "tool.ts"), source)
    File.write!(Path.join(tmp, "tool_test.ts"), test_source)

    granted = Keyword.get(opts, :sandbox) || %{}
    image   = granted["image"] || Application.get_env(:shem, :executor_image_js, "docker.io/denoland/deno:alpine")
    timeout = Application.get_env(:shem, :executor_timeout_ms, 30_000)

    extra_mounts =
      for m <- granted["mounts"] || [], do: {Path.expand(m["host"]), m["container"], Map.get(m, "mode", "ro")}

    # --no-check: this gate accepts plain JS (`export function run(a)` trips Deno's
    #   default TS implicit-any check); we test runtime behaviour, not TS strictness.
    #   A failing assertion still exits non-zero → {:error, :gate, _}, so the gate's
    #   reject path is unaffected.
    # --allow-net/--allow-read: the TEST may import jsr:@std/assert (net) and read
    #   ./tool.ts. This is the throwaway-container test sandbox ONLY — graduated tools
    #   run deny-all via PortPool (no --allow-* on the runtime path).
    result =
      Executor.run_shell(
        "cd /workspace && deno test --no-check --allow-net --allow-read tool_test.ts",
        timeout,
        image: image,
        mounts: [{tmp, "/workspace"} | extra_mounts]
      )

    File.rm_rf!(tmp)

    case result do
      {:ok, _output}   -> build_and_register(source, test_source, id, opts)
      {:error, reason} -> {:error, :gate, reason}
    end
  end

  def unique_id(source) do
    :crypto.hash(:sha256, source)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  # Derive a readable, UNIQUE tool name. The tool's function is always `run`, so the
  # name comes from an optional `// name: ToolName` comment (taught by js_toolsmith).
  # Without it, fall back to an id-suffixed name — never a bare constant, because the
  # model path resolves tool calls by NAME (Enum.find on the manifest), so duplicate
  # names would shadow each other and make the second tool unreachable.
  def extract_name(source, id) do
    case Regex.run(~r/^\s*\/\/\s*name:\s*(\S+)/m, source) do
      [_, name] -> name
      _ -> "js_tool_#{id}"
    end
  end

  defp build_and_register(source, test_source, id, opts) do
    rt = Workspace.runtime_path(id, "javascript")

    tool = %Tool{
      id: id,
      name: Keyword.get(opts, :name) || extract_name(source, id),
      runtime: {:port, rt},
      source: source,
      test_source: test_source,
      constraints: Keyword.get(opts, :constraints, []),
      graduated_at: DateTime.utc_now(),
      metadata: %{
        "language"    => "javascript",
        "description" => Keyword.get(opts, :description, ""),
        "schema"      => Keyword.get(opts, :schema, %{}),
        "actions"     => Keyword.get(opts, :actions) || []
      }
    }

    Shem.Lab.GraduationGate.Common.register_and_seed(tool)
  end
end
