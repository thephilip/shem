defmodule Shem.MCP.Handlers.AgentStatus do
  alias Shem.MCP.Handlers.AgentCommon
  alias Shem.MCP.Schema

  @schema %{"agent_id" => %{"type" => "string"}}

  @spec call(map()) :: {:ok, map()} | {:error, atom(), any()}
  def call(args) do
    with {:ok, valid} <- Schema.validate(args, @schema) do
      session_id = valid["agent_id"]

      case AgentCommon.find_by_session(session_id) do
        {:ok, name} -> live_status(name, session_id)
        :not_found -> tombstone(session_id)
      end
    end
  end

  defp live_status(name, session_id) do
    case Shem.Agent.status(name) do
      {:ok, status} ->
        {events, count} =
          case AgentCommon.session_events(session_id) do
            {:ok, events} -> {events, length(events)}
            {:error, _} -> {[], 0}
          end

        output = if status == :running, do: "", else: AgentCommon.final_output(events)

        {:ok,
         %{
           "agent_id" => session_id,
           "status" => Atom.to_string(status),
           "output" => output,
           "events" => count
         }}

      # agent died between registry lookup and the status call
      {:error, :not_found} ->
        tombstone(session_id)
    end
  end

  defp tombstone(session_id) do
    case AgentCommon.session_events(session_id) do
      {:ok, events} ->
        {:ok,
         %{
           "agent_id" => session_id,
           "status" => AgentCommon.tombstone_status(events),
           "output" => AgentCommon.final_output(events),
           "events" => length(events)
         }}

      {:error, _} ->
        {:error, :not_found, "no agent with id #{session_id}"}
    end
  end
end
