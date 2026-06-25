defmodule Shem.Lab.Workspace do
  alias Shem.Tool

  def messy_path(id), do: Path.join([lab_dir(), "messy", "#{id}.ex"])
  def graduated_path(id), do: Path.join([lab_dir(), "graduated", "#{id}.ex"])
  def manifest_path(id), do: Path.join([lab_dir(), "graduated", "#{id}.json"])
  def runtime_path(id, language) do
    Path.join([lab_dir(), "graduated", "#{id}_runtime.#{Shem.Lab.Languages.ext(language)}"]) |> Path.expand()
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
        ext = Shem.Lab.Languages.ext(language)
        File.write!(Path.join(dir, "#{tool.id}.#{ext}"), tool.source)
        File.write!(runtime_path, Shem.Lab.Languages.wrapper(language, tool.source))
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
      "constraints"  => tool.constraints,
      "test_source"  => tool.test_source,
      "graduated_at" => DateTime.to_iso8601(tool.graduated_at)
    }
    |> Jason.encode!(pretty: true)
  end

  defp build_manifest(%Tool{runtime: {:port, runtime_path}} = tool) do
    %{
      "id"           => tool.id,
      "name"         => tool.name,
      "language"     => Map.get(tool.metadata, "language", "python"),
      "runtime_path" => runtime_path,
      "description"  => Map.get(tool.metadata, "description", ""),
      "schema"       => Map.get(tool.metadata, "schema", %{}),
      "constraints"  => tool.constraints,
      "test_source"  => tool.test_source,
      "graduated_at" => DateTime.to_iso8601(tool.graduated_at)
    }
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
