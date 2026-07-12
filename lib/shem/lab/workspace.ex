defmodule Shem.Lab.Workspace do
  alias Shem.Tool

  def messy_path(id), do: Path.join([lab_dir(), "messy", "#{id}.ex"])
  def graduated_path(id), do: Path.join([lab_dir(), "graduated", "#{id}.ex"])
  def manifest_path(id), do: Path.join([lab_dir(), "graduated", "#{id}.json"])
  # Does `name` (a bare filename in graduated/) belong to tool `id`? Matches the
  # manifest, source, and the `_runtime` file OR dir — without sweeping in a sibling
  # whose id is a prefix (e.g. `parse` must not match `parse_json`'s files).
  def own_file?(id, name) do
    name == id or
      String.starts_with?(name, "#{id}.") or
      name == "#{id}_runtime" or
      String.starts_with?(name, "#{id}_runtime.")
  end

  def runtime_path(id, language) do
    base = Path.join([lab_dir(), "graduated", "#{id}_runtime"])

    case Shem.Lab.Languages.layout(language) do
      :file -> "#{base}.#{Shem.Lab.Languages.ext(language)}" |> Path.expand()
      :dir  -> Path.expand(base)
    end
  end

  @spec graduate(Tool.t()) :: :ok
  def graduate(%Tool{} = tool) do
    dir = Path.join(lab_dir(), "graduated")
    File.mkdir_p!(dir)

    case tool.runtime do
      {:beam, _mod} ->
        File.write!(graduated_path(tool.id), tool.source)

      {:port, runtime_path} ->
        language = Map.get(tool.metadata, "language", "python")

        case Shem.Lab.Languages.layout(language) do
          :file ->
            ext = Shem.Lab.Languages.ext(language)
            File.write!(Path.join(dir, "#{tool.id}.#{ext}"), tool.source)
            File.write!(runtime_path, Shem.Lab.Languages.wrapper(language, tool.source))

          :dir ->
            File.mkdir_p!(runtime_path)
            for {name, content} <- Shem.Lab.Languages.dir_files(language, tool.source) do
              File.write!(Path.join(runtime_path, name), content)
            end
        end
    end

    File.write!(manifest_path(tool.id), build_manifest(tool))
    :ok
  end

  @spec list_graduated() :: [{String.t(), String.t()} | {:legacy, String.t(), String.t()}]
  def list_graduated do
    dir = Path.join(lab_dir(), "graduated")
    File.mkdir_p!(dir)

    json_entries =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(fn filename ->
        id = String.replace_suffix(filename, ".json", "")
        {id, Path.join(dir, filename)}
      end)

    legacy_entries =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.reject(fn filename ->
        id = String.replace_suffix(filename, ".ex", "")
        File.exists?(manifest_path(id))
      end)
      |> Enum.map(fn filename ->
        id = String.replace_suffix(filename, ".ex", "")
        {:legacy, id, Path.join(dir, filename)}
      end)

    json_entries ++ legacy_entries
  end

  defp build_manifest(%Tool{runtime: {:beam, _}} = tool) do
    %{
      "id"           => tool.id,
      "name"         => tool.name,
      "language"     => "elixir",
      "description"  => Map.get(tool.metadata, "description", ""),
      "schema"       => Map.get(tool.metadata, "schema", %{}),
      "actions"      => Map.get(tool.metadata, "actions", []),
      "constraints"  => tool.constraints,
      "test_source"  => tool.test_source,
      "graduated_at" => DateTime.to_iso8601(tool.graduated_at)
    }
    |> Jason.encode!(pretty: true)
  end

  defp build_manifest(%Tool{runtime: {:port, runtime_path}} = tool) do
    granted = Map.get(tool.metadata, "granted", %{})

    %{
      "id"           => tool.id,
      "name"         => tool.name,
      "language"     => Map.get(tool.metadata, "language", "python"),
      "runtime_path" => runtime_path,
      "description"  => Map.get(tool.metadata, "description", ""),
      "schema"       => Map.get(tool.metadata, "schema", %{}),
      "actions"      => Map.get(tool.metadata, "actions", []),
      "constraints"  => tool.constraints,
      "test_source"  => tool.test_source,
      "graduated_at" => DateTime.to_iso8601(tool.graduated_at)
    }
    # empty grants omit the key entirely — same convention as Pack.install
    |> then(&if granted == %{}, do: &1, else: Map.put(&1, "granted", granted))
    |> Jason.encode!(pretty: true)
  end

  defp lab_dir do
    Application.get_env(
      :shem,
      :lab_dir,
      Path.join([System.user_home!(), ".config", "shem", "lab"])
    )
  end
end
