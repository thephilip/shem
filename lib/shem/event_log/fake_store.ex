defmodule Shem.EventLog.FakeStore do
  @behaviour Shem.EventLog.Store

  @impl true
  def open(session_id, _path) do
    table =
      :ets.new(
        :"fake_store_#{session_id}_#{:erlang.unique_integer([:positive])}",
        [:set, :public, :named_table]
      )
    {:ok, table}
  end

  @impl true
  def append(table, event) do
    :ets.insert(table, {event.id, event})
    :ok
  end

  @impl true
  def read_all(table) do
    events =
      table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, event} -> event end)
      |> Enum.sort_by(fn e -> {Map.get(e, :seq) || -1, DateTime.to_unix(e.timestamp, :microsecond)} end)
    {:ok, events}
  end

  @impl true
  def get(table, event_id) do
    case :ets.lookup(table, event_id) do
      [{^event_id, event}] -> {:ok, event}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def scrub(table, after_event_id) do
    {:ok, events} = read_all(table)

    case Enum.find_index(events, &(&1.id == after_event_id)) do
      nil ->
        {:error, :event_not_found}

      cut_index ->
        events
        |> Enum.drop(cut_index + 1)
        |> Enum.each(fn event -> :ets.delete(table, event.id) end)

        :ok
    end
  end

  @impl true
  def close(table) do
    try do
      :ets.delete(table)
    rescue
      ArgumentError -> :ok
    end
    :ok
  end
end
