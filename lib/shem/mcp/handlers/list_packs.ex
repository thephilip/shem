defmodule Shem.MCP.Handlers.ListPacks do
  alias Shem.Lab.Pack

  @spec call(map()) :: {:ok, map()}
  def call(_args), do: {:ok, %{packs: Pack.list_packs()}}
end
