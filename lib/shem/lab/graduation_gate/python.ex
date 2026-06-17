defmodule Shem.Lab.GraduationGate.Python do
  alias Shem.Lab.{Workspace, Executor, Registry}
  alias Shem.Tool

  def run(source, test_source, opts) do
    id = unique_id(source)
    tmp_dir = Path.join(System.tmp_dir!(), "shem_grad_#{id}")
    File.mkdir_p!(tmp_dir)

    File.write!(Path.join(tmp_dir, "tool.py"), source)
    File.write!(Path.join(tmp_dir, "test_tool.py"), test_source)

    image   = Application.get_env(:shem, :executor_image_python, "python:3.12-slim")
    timeout = Application.get_env(:shem, :executor_timeout_ms, 30_000)

    result =
      Executor.run_shell(
        "cd /workspace && pip install pytest -q --no-warn-script-location 2>/dev/null && pytest test_tool.py -q",
        timeout,
        image: image,
        mounts: [{tmp_dir, "/workspace"}]
      )

    File.rm_rf!(tmp_dir)

    case result do
      {:ok, _output} -> build_and_register(source, test_source, id, opts)
      {:error, reason} -> {:error, :gate, reason}
    end
  end

  def extract_name(source) do
    if source =~ ~r/def run\(/m do
      source
      |> String.split("\n")
      |> Enum.find(&(&1 =~ ~r/^class \w+|^# name:/))
      |> case do
        nil ->
          "python_tool"

        line ->
          line
          |> String.replace(~r/^(class |# name:)\s*/, "")
          |> String.trim()
          |> String.trim_trailing(":")
      end
    else
      "python_tool"
    end
  end

  def unique_id(source) do
    :crypto.hash(:sha256, source)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp build_and_register(source, test_source, id, opts) do
    description  = Keyword.get(opts, :description, "")
    schema       = Keyword.get(opts, :schema, %{})
    constraints  = Keyword.get(opts, :constraints, [])
    name         = Keyword.get(opts, :name, extract_name(source))
    runtime_path = Workspace.runtime_path(id)

    tool = %Tool{
      id: id,
      name: name,
      runtime: {:port, runtime_path},
      source: source,
      test_source: test_source,
      constraints: constraints,
      graduated_at: DateTime.utc_now(),
      metadata: %{
        "language"    => "python",
        "description" => description,
        "schema"      => schema
      }
    }

    :ok = Workspace.graduate(tool)
    :ok = Registry.register(tool)
    seed_trust(tool.id)
    Shem.Adversarial.start_hardening(tool.id)
    {:ok, tool}
  end

  defp seed_trust(tool_id) do
    Shem.Trust.Store.seed(tool_id, 0.5)
  catch
    :exit, _ -> :ok
  end
end
