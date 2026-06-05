defmodule Shem.Agent.Checkpoint do
  alias Shem.EventLog

  @spec save(String.t(), map()) :: :ok
  def save(session_id, state) do
    EventLog.append(session_id, :agent_checkpoint, %{
      history: state.history,
      turn_count: state.turn_count,
      config: state.config
    })
    :ok
  end

  @spec reconstruct(String.t()) :: {:ok, map()} | :not_found
  def reconstruct(session_id) do
    case EventLog.events(session_id) do
      {:ok, events} ->
        events
        |> Enum.filter(&(&1.type == :agent_checkpoint))
        |> List.last()
        |> case do
          nil -> :not_found
          event -> {:ok, event.payload}
        end

      _ ->
        :not_found
    end
  end
end
