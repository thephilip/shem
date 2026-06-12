defmodule Shem.MCP.Handlers.ListAgents do
  alias Shem.MCP.Handlers.AgentCommon

  @spec call(map()) :: {:ok, map()}
  def call(_args) do
    agents =
      AgentCommon.live_agents()
      |> Enum.map(fn {name, session_id} ->
        status =
          case Shem.Agent.status(name) do
            {:ok, s} -> Atom.to_string(s)
            {:error, :not_found} -> "error"
          end

        {goal, count} =
          case AgentCommon.session_events(session_id) do
            {:ok, events} -> {AgentCommon.goal(events), length(events)}
            {:error, _} -> {"", 0}
          end

        %{"agent_id" => session_id, "status" => status, "goal" => goal, "events" => count}
      end)

    {:ok, %{"agents" => agents}}
  end
end
