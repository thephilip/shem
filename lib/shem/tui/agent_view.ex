defmodule Shem.TUI.AgentView do
  defstruct [
    :agent_name,
    status: :running,
    turn_count: 0,
    max_turns: 20,
    current_reasoning: nil,
    last_tool_call: nil,
    history: [],
    recent_events: []
  ]

  @type t :: %__MODULE__{
          agent_name: String.t() | nil,
          status: :running | :done | :error,
          turn_count: non_neg_integer(),
          max_turns: pos_integer(),
          current_reasoning: String.t() | nil,
          last_tool_call: %{name: String.t(), args: map(), result: String.t() | nil} | nil,
          history: [%{turn: non_neg_integer(), tool: String.t() | nil}],
          recent_events: [atom()]
        }

  @spec build(String.t()) :: {:ok, t()} | :not_found
  def build(session_id) do
    case Shem.EventLog.events(session_id) do
      {:ok, []} ->
        :not_found

      {:ok, events} ->
        view = Enum.reduce(events, %__MODULE__{}, &fold_event/2)
        recent = events |> Enum.map(& &1.type) |> Enum.take(-10)
        {:ok, %{view | recent_events: recent}}

      _ ->
        :not_found
    end
  end

  defp fold_event(event, acc) do
    case event.type do
      :agent_started ->
        %{acc | max_turns: event.payload[:max_turns] || 20}

      :agent_turn_started ->
        %{acc | turn_count: event.payload[:turn] || acc.turn_count + 1, last_tool_call: nil}

      :llm_call_completed ->
        content = event.payload[:content] || ""
        %{acc | current_reasoning: content}

      :agent_tool_called ->
        %{
          acc
          | last_tool_call: %{
              name: event.payload[:tool],
              args: event.payload[:args] || %{},
              result: nil
            }
        }

      :agent_tool_result ->
        case acc.last_tool_call do
          nil -> acc
          tc -> %{acc | last_tool_call: %{tc | result: event.payload[:result]}}
        end

      :agent_turn_completed ->
        tool_name = if acc.last_tool_call, do: acc.last_tool_call.name, else: nil
        entry = %{turn: acc.turn_count, tool: tool_name}
        %{acc | history: acc.history ++ [entry], last_tool_call: nil}

      :agent_done ->
        %{acc | status: :done}

      :agent_error ->
        %{acc | status: :error}

      _ ->
        acc
    end
  end
end
