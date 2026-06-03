defmodule Shem.Lab.Workspace do
  alias Shem.Tool

  def messy_path(id), do: Path.join([lab_dir(), "messy", "#{id}.ex"])
  def graduated_path(id), do: Path.join([lab_dir(), "graduated", "#{id}.ex"])

  @spec graduate(Tool.t()) :: :ok
  def graduate(%Tool{} = tool) do
    path = graduated_path(tool.id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, tool.source)
  end

  @spec list_graduated() :: [{String.t(), String.t()}]
  def list_graduated do
    dir = Path.join(lab_dir(), "graduated")
    File.mkdir_p!(dir)

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.map(fn filename ->
      id = String.trim_trailing(filename, ".ex")
      {id, Path.join(dir, filename)}
    end)
  end

  defp lab_dir do
    Application.get_env(
      :shem,
      :lab_dir,
      Path.join([System.user_home!(), ".config", "shem", "lab"])
    )
  end
end
