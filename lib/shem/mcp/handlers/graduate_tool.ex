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
          {:ok, updated}

        error ->
          error
      end
    end
  end
end
