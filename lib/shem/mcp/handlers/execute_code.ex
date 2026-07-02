defmodule Shem.MCP.Handlers.ExecuteCode do
  alias Shem.Lab.Executor
  alias Shem.MCP.Schema

  @schema %{"source" => %{"type" => "string"}}

  @spec call(map()) :: {:ok, any()} | {:error, atom(), any()}
  def call(args) do
    with {:ok, valid} <- Schema.validate(args, @schema) do
      Executor.run(valid["source"], fn mod -> mod.run() end, scan: false)
    end
  end
end
