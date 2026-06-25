defmodule Shem.Lab.GraduationGate.JS do
  alias Shem.Lab.{Workspace, Executor, Registry}
  alias Shem.Tool

  def run(source, test_source, opts) do
    id = unique_id(source)
    tmp = Path.join(System.tmp_dir!(), "shem_grad_js_#{id}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "tool.ts"), source)
    File.write!(Path.join(tmp, "tool_test.ts"), test_source)

    image   = Application.get_env(:shem, :executor_image_js, "docker.io/denoland/deno:alpine")
    timeout = Application.get_env(:shem, :executor_timeout_ms, 30_000)

    result =
      Executor.run_shell(
        "cd /workspace && deno test --no-check --allow-net --allow-read tool_test.ts",
        timeout,
        image: image,
        mounts: [{tmp, "/workspace"}]
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

  defp build_and_register(source, test_source, id, opts) do
    rt = Workspace.runtime_path(id, "javascript")

    tool = %Tool{
      id: id,
      name: Keyword.get(opts, :name, "js_tool"),
      runtime: {:port, rt},
      source: source,
      test_source: test_source,
      constraints: Keyword.get(opts, :constraints, []),
      graduated_at: DateTime.utc_now(),
      metadata: %{
        "language"    => "javascript",
        "description" => Keyword.get(opts, :description, ""),
        "schema"      => Keyword.get(opts, :schema, %{})
      }
    }

    :ok = Workspace.graduate(tool)
    :ok = Registry.register(tool)
    seed_trust(tool.id, 0.5)
    {:ok, tool}
  end

  defp seed_trust(tool_id, score) do
    Shem.Trust.Store.seed(tool_id, score)
  catch
    :exit, _ -> :ok
  end
end
