defmodule Shem.EventLog.HistoryScanner do
  alias Shem.EventLog

  @enforce_keys [:session_id]
  defstruct [:session_id, :task, :started_at, :status, :turn_count]

  @type status :: :done | :error | :running | :unknown

  @type t :: %__MODULE__{
          session_id: String.t(),
          task: String.t() | nil,
          started_at: DateTime.t() | nil,
          status: status(),
          turn_count: non_neg_integer()
        }

  @spec scan() :: [t()]
  def scan do
    path = event_log_path()
    active_ids = active_session_ids()

    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".dets"))
        |> Enum.map(&String.replace_suffix(&1, ".dets", ""))
        |> Enum.reject(&MapSet.member?(active_ids, &1))
        |> Enum.flat_map(&build_summary(&1))
        |> Enum.sort_by(&(&1.started_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})

      {:error, _} ->
        []
    end
  end

  defp event_log_path do
    Application.get_env(
      :shem,
      :event_log_path,
      Path.join([System.user_home!(), ".config", "shem", "lab", "events"])
    )
  end

  defp active_session_ids do
    case EventLog.list_sessions() do
      {:ok, sessions} ->
        sessions
        |> Enum.filter(&is_nil(&1.ended_at))
        |> Enum.map(& &1.id)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp build_summary(session_id) do
    try do
      case EventLog.read_session_events(session_id) do
        {:ok, events} ->
          [%__MODULE__{
            session_id: session_id,
            task: extract_task(events),
            started_at: extract_started_at(events),
            status: infer_status(events),
            turn_count: Enum.count(events, &(&1.type == :agent_turn_completed))
          }]

        _ ->
          []
      end
    catch
      :exit, _ -> []
    end
  end

  defp extract_task(events) do
    case Enum.find(events, &(&1.type == :agent_started)) do
      nil -> nil
      event -> event.payload[:task]
    end
  end

  defp extract_started_at([]), do: nil
  defp extract_started_at([first | _]), do: first.timestamp

  defp infer_status(events) do
    cond do
      Enum.any?(events, &(&1.type == :agent_done)) -> :done
      Enum.any?(events, &(&1.type == :agent_error)) -> :error
      true -> :unknown
    end
  end
end
