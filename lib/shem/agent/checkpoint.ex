defmodule Shem.Agent.Checkpoint do
  alias Shem.EventLog

  @spec save(String.t(), map()) :: :ok | {:error, term()}
  def save(session_id, state) do
    case EventLog.append(session_id, :agent_checkpoint, %{
           history: state.history,
           turn_count: state.turn_count,
           config: state.config,
           node: Node.self()
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reconstruct(String.t()) :: {:ok, map()} | :not_found
  def reconstruct(session_id) do
    case EventLog.read_session_events(session_id) do
      {:ok, events} ->
        case events |> Enum.filter(&(&1.type == :agent_checkpoint)) |> List.last() do
          nil ->
            :not_found

          cp ->
            # events appended after the last checkpoint (read order is append order)
            tail = events |> Enum.drop_while(&(&1.id != cp.id)) |> Enum.drop(1)
            base = cp.payload
            {history, added_turns} = fold_tail(tail, Map.get(base, :history, []), 0)
            {:ok, %{base | history: history, turn_count: Map.get(base, :turn_count, 0) + added_turns}}
        end

      _ ->
        :not_found
    end
  end

  # Mirror how the live turn loop builds history: an llm answer becomes an
  # assistant message (and completes a turn), a tool result becomes a tool message.
  defp fold_tail([], history, turns), do: {history, turns}

  defp fold_tail([e | rest], history, turns) do
    p = e.payload || %{}

    case e.type do
      :llm_call_completed ->
        fold_tail(rest, history ++ [%{role: :assistant, content: Map.get(p, :content, "")}], turns + 1)

      :agent_tool_result ->
        msg = "Tool result (#{Map.get(p, :tool, "")}): #{Map.get(p, :result, "")}"
        fold_tail(rest, history ++ [%{role: :tool, content: msg}], turns)

      _ ->
        fold_tail(rest, history, turns)
    end
  end
end
