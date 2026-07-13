defmodule Shem.MCP.Handlers.GraduateTool do
  alias Shem.Lab.{GraduationGate, Registry}
  alias Shem.MCP.Schema

  @schema %{
    "source" => %{"type" => "string"},
    "test_source" => %{"type" => "string"},
    "input_schema" => %{"type" => "object", "required" => false}
  }

  @spec call(map()) :: {:ok, Shem.Tool.t()} | {:error, atom(), any()}
  def call(args) do
    with {:ok, valid} <- Schema.validate(args, @schema) do
      input_schema = Map.get(valid, "input_schema", %{})
      constraints = Map.get(valid, "constraints", [])

      case GraduationGate.run(valid["source"], valid["test_source"], constraints) do
        {:ok, tool} ->
          updated = %{tool | input_schema: input_schema}
          :ok = Registry.register(updated)
          {:ok, summarize(updated)}

        error ->
          error
      end
    end
  end

  # %Shem.Tool{} isn't JSON-encodable (tuple runtime), so hand back a plain map —
  # and spend the result to reinforce the loop: graduation persists, so the model
  # should reach for invoke_tool next time instead of rewriting the code.
  defp summarize(tool) do
    %{
      "id" => tool.id,
      "name" => tool.name,
      "input_schema" => tool.input_schema,
      "note" =>
        "Graduated and persisted. Call it in any future session with " <>
          "invoke_tool(id: \"#{tool.id}\") instead of rewriting this code."
    }
  end
end
