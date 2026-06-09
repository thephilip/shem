defmodule Shem.Context.Project do
  @moduledoc "Detects working directory context and formats it for agent system prompt injection."

  @enforce_keys [:path, :name, :type, :contents, :git_repo?]
  defstruct [:path, :name, :type, :contents, :git_repo?]

  @type t :: %__MODULE__{
    path: String.t(),
    name: String.t(),
    type: atom(),
    contents: [{String.t(), :file | :dir}],
    git_repo?: boolean()
  }

  @type_markers [
    {:elixir, ["mix.exs"]},
    {:rust, ["Cargo.toml"]},
    {:node, ["package.json"]},
    {:python, ["pyproject.toml", "setup.py", "requirements.txt"]},
    {:go, ["go.mod"]},
    {:ruby, ["Gemfile"]}
  ]

  @spec detect(String.t() | nil) :: t()
  def detect(dir \\ nil) do
    path = dir || File.cwd!()
    entries = list_entries(path)
    names = Enum.map(entries, fn {name, _} -> name end)

    %__MODULE__{
      path: path,
      name: Path.basename(path),
      type: detect_type(names),
      contents: entries,
      git_repo?: File.dir?(Path.join(path, ".git"))
    }
  end

  @spec to_prompt(t()) :: String.t()
  def to_prompt(%__MODULE__{} = ctx) do
    git_note = if ctx.git_repo?, do: " (git repo)", else: ""
    type_label = type_label(ctx.type)
    contents_str = format_contents(ctx.contents)

    """
    Working directory: #{ctx.path}
    Project: #{ctx.name} — #{type_label}#{git_note}
    Contents: #{contents_str}
    """
  end

  # --- private ---

  defp list_entries(path) do
    case File.ls(path) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.map(fn name ->
          full = Path.join(path, name)
          type = if File.dir?(full), do: :dir, else: :file
          {name, type}
        end)

      {:error, _} ->
        []
    end
  end

  defp detect_type(names) do
    Enum.find_value(@type_markers, :unknown, fn {type, markers} ->
      if Enum.any?(markers, &(&1 in names)), do: type
    end)
  end

  defp type_label(:elixir), do: "Elixir/Mix"
  defp type_label(:node), do: "Node.js"
  defp type_label(:rust), do: "Rust/Cargo"
  defp type_label(:python), do: "Python"
  defp type_label(:go), do: "Go"
  defp type_label(:ruby), do: "Ruby"
  defp type_label(:unknown), do: "unknown project type"

  defp format_contents(entries) do
    entries
    |> Enum.map(fn
      {name, :dir} -> "#{name}/"
      {name, :file} -> name
    end)
    |> Enum.join(", ")
  end
end
