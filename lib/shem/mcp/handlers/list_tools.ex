defmodule Shem.MCP.Handlers.ListTools do
  alias Shem.Lab.Registry

  @spec call(map()) :: {:ok, [map()]}
  def call(_args) do
    tools =
      Registry.all()
      |> Enum.map(fn tool ->
        %{
          "id" => tool.id,
          "name" => tool.name,
          "input_schema" => tool.input_schema
        }
      end)

    {:ok, tools}
  end
end
