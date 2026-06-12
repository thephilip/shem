defmodule Shem.MCP.Handlers.SpawnAgent do
  alias Shem.MCP.Schema

  @schema %{
    "goal" => %{"type" => "string"},
    "preset" => %{"type" => "string", "required" => false}
  }

  @spec call(map()) :: {:ok, map()} | {:error, atom(), any()}
  def call(args) do
    with {:ok, valid} <- Schema.validate(args, @schema) do
      preset = Map.get(valid, "preset", "general")

      case Shem.Agent.start_with_preset(preset, valid["goal"]) do
        {:ok, _name, session_id} ->
          {:ok, %{"agent_id" => session_id, "status" => "running"}}

        {:error, :not_found} ->
          {:error, :invalid_args, "unknown preset: #{preset}"}

        {:error, reason} ->
          {:error, :spawn_failed, inspect(reason)}
      end
    end
  end
end
