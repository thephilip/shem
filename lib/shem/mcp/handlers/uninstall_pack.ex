defmodule Shem.MCP.Handlers.UninstallPack do
  alias Shem.Lab.Pack
  alias Shem.MCP.Schema

  @schema %{"name" => %{"type" => "string"}}

  @spec call(map()) :: {:ok, map()} | {:error, term()}
  def call(args) do
    with {:ok, valid} <- Schema.validate(args, @schema) do
      Pack.uninstall(valid["name"])
    end
  end
end
