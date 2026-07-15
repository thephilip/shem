defmodule Shem.MCP.Handlers.ListTools do
  alias Shem.Lab.Registry

  @empty_note "No graduated tools yet. Write code once, graduate_tool it, and it " <>
                "persists here — callable in every future session without rewriting."

  @note "Invoke these with invoke_tool using the tool's id (not its name). Just " <>
          "wrote code you'd want again? graduate_tool persists it here for every " <>
          "future session."

  @spec call(map()) :: {:ok, map()}
  def call(_args) do
    tools = Enum.map(Registry.all(), &summary/1)

    {:ok,
     %{
       "tools" => tools,
       "note" => if(tools == [], do: @empty_note, else: @note)
     }}
  end

  defp summary(tool) do
    %{
      "id" => tool.id,
      "name" => tool.name,
      "description" => tool.metadata["description"] || "",
      "input_schema" => schema(tool)
    }
  end

  # Two homes for the same schema: seed tools set input_schema on the struct,
  # manifest-loaded (pack/graduated) tools land theirs in metadata["schema"].
  defp schema(%{input_schema: s}) when map_size(s) > 0, do: s
  defp schema(tool), do: tool.metadata["schema"] || %{}
end
