defmodule Shem.Lab.GraduationGate do
  alias Shem.Tool

  @builtin_languages %{
    "elixir" => :elixir,
    "python" => :python,
    "javascript" => :javascript,
    "go" => :go
  }

  @spec run(String.t(), String.t(), keyword()) ::
          {:ok, Tool.t()}
          | {:error, :compile, String.t()}
          | {:error, :gate, any()}
          | {:error, :timeout}
          | {:error, :language_not_configured, String.t()}
  def run(source, test_source, opts \\ []) do
    lang = Keyword.get(opts, :language, "elixir")
    languages = Application.get_env(:shem, :graduation_languages, @builtin_languages)

    case Map.get(languages, lang) do
      :elixir     -> Shem.Lab.GraduationGate.Elixir.run(source, test_source, opts)
      :python     -> Shem.Lab.GraduationGate.Python.run(source, test_source, opts)
      :javascript -> Shem.Lab.GraduationGate.JS.run(source, test_source, opts)
      :go         -> Shem.Lab.GraduationGate.Go.run(source, test_source, opts)
      nil         -> {:error, :language_not_configured, lang}
    end
  end

end
