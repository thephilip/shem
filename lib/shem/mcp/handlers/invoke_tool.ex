defmodule Shem.MCP.Handlers.InvokeTool do
  alias Shem.Lab.Registry
  alias Shem.MCP.Schema

  @schema %{
    "id" => %{"type" => "string"},
    "args" => %{"required" => false}
  }

  @spec call(map()) :: {:ok, any()} | {:error, atom()} | {:error, atom(), any()}
  def call(params) do
    with {:ok, valid} <- Schema.validate(params, @schema),
         {:ok, tool} <- Registry.lookup(valid["id"]),
         :ok <- ensure_loaded(tool) do
      args = Map.get(valid, "args", %{})

      with {:ok, _} <- Schema.validate(args, tool.input_schema) do
        result = tool.module.run(args)
        {:ok, result}
      end
    end
  end

  defp ensure_loaded(%{module: module, source: source}) do
    case :code.is_loaded(module) do
      false ->
        case Code.compile_string(source) do
          [{^module, bytecode} | _] ->
            case :code.load_binary(module, ~c"nofile", bytecode) do
              {:module, _} -> :ok
              {:error, _} -> {:error, :load_failed}
            end

          _ ->
            {:error, :load_failed}
        end

      _ ->
        :ok
    end
  end
end
