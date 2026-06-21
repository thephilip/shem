defmodule Shem.Telemetry do
  @moduledoc """
  Real-time observability collector. Attaches to the four Shem `:stop`
  telemetry events and keeps a bounded ring of recent durations per event,
  exposing rolling p50/p99 via `stats/0`.

  Complements EventLog (forensic, "what happened?") with live operational
  stats ("is it on fire?").
  """
  use GenServer

  @ring_size 256

  @events [
    [:shem, :agent, :turn, :stop],
    [:shem, :event_log, :append, :stop],
    [:shem, :port_pool, :roundtrip, :stop],
    [:shem, :llm, :call, :stop]
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Rolling stats keyed by `{event, group}`: `%{{event, group} => %{count, p50_ms, p99_ms}}`.
  `group` is `nil` unless the span set a `:group` in its metadata (LLM spans
  set `group: request.model` so per-model latency stays unblended).
  """
  @spec stats() :: %{{[atom()], term()} => %{count: non_neg_integer(), p50_ms: float(), p99_ms: float()}}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(_opts) do
    :telemetry.attach_many(
      "shem-telemetry-collector",
      @events,
      &__MODULE__.handle_event/4,
      nil
    )

    {:ok, %{}}
  end

  @doc false
  # Runs in the caller's process; forwards the duration to the collector.
  def handle_event(event, %{duration: duration}, meta, _config) do
    GenServer.cast(__MODULE__, {:record, {event, meta[:group]}, duration})
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  @impl true
  def handle_cast({:record, key, duration_native}, state) do
    ms = System.convert_time_unit(duration_native, :native, :nanosecond) / 1_000_000
    ring = [ms | Map.get(state, key, [])] |> Enum.take(@ring_size)
    {:noreply, Map.put(state, key, ring)}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.new(state, fn {key, ring} ->
        {key, %{count: length(ring), p50_ms: percentile(ring, 50), p99_ms: percentile(ring, 99)}}
      end)

    {:reply, stats, state}
  end

  # ponytail: sort-on-read, O(n log n) per stats/0 call; swap for an hdr
  # histogram if read-rate ever hurts. n is bounded at #{@ring_size}.
  @doc false
  def percentile([], _p), do: 0.0

  def percentile(ring, p) do
    sorted = Enum.sort(ring)
    idx = max(0, round(p / 100 * length(sorted)) - 1)
    Enum.at(sorted, idx)
  end
end
