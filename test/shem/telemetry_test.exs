defmodule Shem.TelemetryTest do
  use ExUnit.Case, async: false

  alias Shem.Telemetry

  # Percentile math is the only non-trivial logic; the collector itself is a
  # global shared by the running app, so we test the pure function directly
  # rather than racing other tests' events into the shared ring.
  test "percentile computes p50/p99 over a sample" do
    ring = Enum.shuffle(1..100) |> Enum.map(&(&1 * 1.0))

    assert Telemetry.percentile(ring, 50) == 50.0
    assert Telemetry.percentile(ring, 99) == 99.0
    assert Telemetry.percentile([], 50) == 0.0
  end

  test "stats/0 keys by {event, group}, splitting by metadata group" do
    event = [:shem, :llm, :call, :stop]
    dur = System.convert_time_unit(5, :millisecond, :native)

    :telemetry.execute(event, %{duration: dur}, %{group: "stub-model"})
    :telemetry.execute(event, %{duration: dur}, %{node: node()})

    Process.sleep(50)

    stats = Telemetry.stats()
    assert is_map(stats)
    # Grouped (per-model) and ungrouped entries are kept separate, not blended.
    assert Map.has_key?(stats, {event, "stub-model"})
    assert Map.has_key?(stats, {event, nil})
  end
end
