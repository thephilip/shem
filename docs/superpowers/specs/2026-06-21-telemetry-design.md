# Shem.Telemetry — design

_2026-06-21_

## Goal
Real-time observability ("is it on fire?") complementing EventLog's forensic
observability ("what happened?"). Built on BEAM `:telemetry` (already in the
lock file via horde/bandit/finch — no new dependency for the core).

## Build order (each rung independently useful)
1. Events
2. Collector + rolling stats
3. TUI panel
4. Prometheus exporter (optional tail; may land in a later session)

## 1. Events
Emit at four points with `:telemetry.execute/3` (or `:telemetry.span/3` where a
clean wrap exists, which yields `:start`/`:stop`/`:exception` for free):

| Event | Measurement | Metadata |
|---|---|---|
| `[:shem, :agent, :turn, :stop]` | `%{duration: native}` | `%{agent_id, node}` |
| `[:shem, :event_log, :append, :stop]` | `%{duration: native}` | `%{store, node}` |
| `[:shem, :port_pool, :roundtrip, :stop]` | `%{duration: native}` | `%{runtime, node}` |
| `[:shem, :llm, :call, :stop]` | `%{duration: native}` | `%{transport, node}` |

`duration` is in `:native` units (telemetry convention); convert to ms at read.

## 2. Collector — `Shem.Telemetry` GenServer
- `attach_many/4` on boot for the four `:stop` events.
- State: a bounded ring (last N=256 durations) per event key.
- `stats/0` → `%{event_key => %{count, p50_ms, p99_ms}}`, percentiles computed
  on read (sort the ring).
- `ponytail:` ring + sort-on-read is O(n log n) per read; swap for an hdr
  histogram if read-rate ever hurts.

## 3. TUI panel
A stats view rendering `Shem.Telemetry.stats/0` on the existing render tick:
count + p50/p99 ms per event.

## 4. Prometheus exporter (optional tail)
Add `telemetry_metrics`, `telemetry_poller`, `telemetry_metrics_prometheus`;
expose `/metrics` on the existing Bandit router. Documented here; built only if
budget allows this session, otherwise next session.

## Test
`test/shem/telemetry_test.exs`: feed synthetic events to the collector, assert
count and p50/p99 computation.
