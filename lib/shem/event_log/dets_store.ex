defmodule Shem.EventLog.DETSStore do
  @behaviour Shem.EventLog.Store

  @impl true
  def open(session_id, path) do
    File.mkdir_p!(path)
    file = Path.join(path, "#{session_id}.dets") |> String.to_charlist()
    table_name = :"shem_events_#{session_id}"

    case :dets.open_file(table_name, file: file, type: :set) do
      {:ok, table} -> {:ok, table}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def append(table, event) do
    case :dets.insert(table, {event.id, event}) do
      :ok -> :ok
      error -> error
    end
  end

  @impl true
  def read_all(table) do
    events =
      :dets.foldl(fn {_id, event}, acc -> [event | acc] end, [], table)
      |> Enum.sort_by(& &1.timestamp, DateTime)
    {:ok, events}
  end

  @impl true
  def get(table, event_id) do
    case :dets.lookup(table, event_id) do
      [{^event_id, event}] -> {:ok, event}
      [] -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def close(table) do
    :dets.close(table)
    :ok
  end
end
