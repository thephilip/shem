defmodule Shem.MCP.Handlers.StopAgent do
  alias Shem.MCP.Handlers.AgentCommon
  alias Shem.MCP.Schema

  @schema %{"agent_id" => %{"type" => "string"}}

  @spec call(map()) :: {:ok, map()} | {:error, atom(), any()}
  def call(args) do
    with {:ok, valid} <- Schema.validate(args, @schema) do
      session_id = valid["agent_id"]

      with {:ok, name} <- AgentCommon.find_by_session(session_id),
           :ok <- Shem.Agent.stop(name) do
        {:ok, %{"ok" => true}}
      else
        _ -> {:error, :not_found, "no running agent with id #{session_id}"}
      end
    end
  end
end
