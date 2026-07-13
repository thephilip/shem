defmodule Shem.MCP.Handlers.ListTools do
  alias Shem.Lab.Registry

  @spec call(map()) :: {:ok, [map()] | map()}
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

    case tools do
      [] ->
        {:ok,
         %{
           "tools" => [],
           "note" =>
             "No graduated tools yet. Write code once, graduate_tool it, and it " <>
               "persists here — callable in every future session without rewriting."
         }}

      _ ->
        {:ok, tools}
    end
  end
end
