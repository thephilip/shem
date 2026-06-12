defmodule Shem.MCP.Handlers.AgentCommon do
  @moduledoc """
  Shared helpers for the MCP agent tools.

  The public `agent_id` over MCP is the EventLog session_id, because it
  outlives the agent process. `Shem.Registry` stores session_ids as values
  (entries are `{name, pid, session_id}`), so live agents are found by a
  reverse value lookup. Names are filtered to the `"agent_"` prefix to skip
  shadow agents and other registry tenants.

  Note: the REST API (`Shem.REST.Handlers.Agents`) addresses agents by process
  name instead; MCP uses the session_id so agents remain pollable after their
  process terminates.
  """

  alias Shem.EventLog

  @spec find_by_session(String.t()) :: {:ok, String.t()} | :not_found
  def find_by_session(session_id) do
    match = [{{:"$1", :"$2", :"$3"}, [{:==, :"$3", session_id}], [:"$1"]}]

    Shem.Registry
    |> Horde.Registry.select(match)
    |> Enum.filter(&agent_name?/1)
    |> case do
      [name | _] -> {:ok, name}
      [] -> :not_found
    end
  end

  @spec live_agents() :: [{String.t(), String.t()}]
  def live_agents do
    match = [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}]

    Shem.Registry
    |> Horde.Registry.select(match)
    |> Enum.filter(fn {name, _session_id} -> agent_name?(name) end)
  end

  @spec session_events(String.t()) :: {:ok, [EventLog.Event.t()]} | {:error, :not_found}
  def session_events(session_id) do
    case EventLog.events(session_id) do
      {:ok, events} -> {:ok, events}
      {:error, _} -> EventLog.read_session_events(session_id)
    end
  end

  @spec goal([EventLog.Event.t()]) :: String.t()
  def goal(events) do
    case Enum.find(events, &(&1.type == :agent_started)) do
      %{payload: %{task: task}} when is_binary(task) -> task
      _ -> ""
    end
  end

  @spec final_output([EventLog.Event.t()]) :: String.t()
  def final_output(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{type: :agent_done, payload: %{content: content}} -> content
      %{type: :agent_done, payload: %{reason: reason}} -> "stopped: #{reason}"
      %{type: :agent_waiting, payload: %{content: content}} -> content
      _ -> nil
    end)
  end

  @spec tombstone_status([EventLog.Event.t()]) :: String.t()
  def tombstone_status(events) do
    cond do
      Enum.any?(events, &(&1.type == :agent_error)) -> "error"
      Enum.any?(events, &(&1.type == :agent_done)) -> "done"
      Enum.any?(events, &(&1.type == :agent_waiting)) -> "done"
      # no terminal event: the agent was killed mid-run and will never finish
      true -> "error"
    end
  end

  defp agent_name?(name), do: is_binary(name) and String.starts_with?(name, "agent_")
end
