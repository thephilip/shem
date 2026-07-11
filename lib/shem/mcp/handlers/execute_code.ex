defmodule Shem.MCP.Handlers.ExecuteCode do
  alias Shem.Lab.Executor
  alias Shem.MCP.Schema

  @schema %{"source" => %{"type" => "string"}}

  @spec call(map()) :: {:ok, String.t()} | {:error, atom(), any()} | {:error, atom()}
  def call(args) do
    with {:ok, valid} <- Schema.validate(args, @schema) do
      case Executor.run_source(valid["source"]) do
        {:ok, result} -> {:ok, result}
        {:error, msg} -> {:error, :runtime, msg}
      end
    end
  end
end
