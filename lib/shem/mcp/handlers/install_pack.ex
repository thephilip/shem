defmodule Shem.MCP.Handlers.InstallPack do
  alias Shem.Lab.Pack
  alias Shem.MCP.Schema

  @schema %{
    "repo" => %{"type" => "string"},
    "path" => %{"type" => "string", "required" => false}
  }

  @spec call(map()) :: {:ok, map()} | {:error, term()}
  def call(args) do
    with {:ok, valid} <- Schema.validate(args, @schema) do
      Pack.install(valid["repo"], Map.get(valid, "path", "."))
    end
  end
end
