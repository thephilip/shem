# Phase 11: TUI Trust Surfacing — Design

## Goal

Make the trust system visible and useful from the TUI. Agents can now be blocked by the trust gate (Phase 10c), but there is no way to see which tools are rated what, check a score, or understand what `/redteam` accomplished. This phase closes that feedback loop.

## Scope

Three user-facing capabilities:

1. **`/tools`** — lists all Lab tools with trust band and hardening count
2. **`/trust <tool_name>`** — shows a single tool's score, band, hardening count, and last-updated timestamp
3. **Dashboard trust summary** — replaces the static "Lab: idle" label with live band counts

MCP and builtin tools are excluded from all three — their trust bands are fixed and carry no diagnostic value.

## Architecture

### Output surface

`/tools` and `/trust` output is displayed in the interactive view's turn card panel. A new `command_output` field is added to the model (`nil | string`). When the turn card has no active agent and `command_output` is set, it renders the output instead of "No active session". Starting a new agent clears `command_output`.

### Trust.Store: new `entry/1`

`Trust.Store` currently exposes only `score/1` (returns a float). `/trust` needs the full entry — hardening count and last-updated timestamp. A new `entry/1` function returns `{:ok, %{score: float, hardening_count: integer, last_updated: DateTime.t()}}` or `{:error, :unrated}`.

### Dashboard tick

A `trust_counts` field is added to the model (`%{high: integer, medium: integer, low: integer, unrated: integer}`). On every `:tick`, `safe_trust_counts/0` calls `Trust.Store.all/0`, applies `score_to_band/1` to each score, and accumulates counts. The dashboard renders this as a single label replacing "Lab: idle".

## Components

### `lib/shem/trust/store.ex`

Add public function:

```elixir
@spec entry(String.t()) :: {:ok, map()} | {:error, :unrated}
def entry(tool_id) do
  GenServer.call(__MODULE__, {:entry, tool_id})
end
```

Add handler:

```elixir
def handle_call({:entry, tool_id}, _from, state) do
  result =
    case :dets.lookup(state.table, tool_id) do
      [{^tool_id, entry}] -> {:ok, entry}
      [] -> {:error, :unrated}
    end
  {:reply, result, state}
end
```

### `lib/shem/tui/command_dispatch.ex`

Add two new parse results:

- `/tools` → `{:tools}`
- `/trust <name>` → `{:trust, name}`
- `/trust` (no name) → `{:error, "usage: /trust <tool_name>"}`

### `lib/shem/tui/app.ex`

Model additions:

```elixir
command_output: nil,
trust_counts: %{high: 0, medium: 0, low: 0, unrated: 0}
```

New command handlers in `update/2`:

**`{:tools}`** — reads `Lab.Registry.all()`, looks up each tool's trust band via `Trust.Store.score/1`, formats as multiline string, sets `command_output`.

**`{:trust, name}`** — looks up tool by name via `Lab.Registry.lookup_by_name/1`, calls `Trust.Store.entry/1`, formats score/band/hardening_count/last_updated, sets `command_output`. On unknown tool: sets `command_error`.

**`{:start_agent, ...}`** — clears `command_output` when an agent starts (existing handler, add `command_output: nil`).

Tick update — add `trust_counts: safe_trust_counts()`.

New private helpers:

```elixir
defp safe_trust_counts do
  try do
    all_tools = Shem.Lab.Registry.all()
    scored = Shem.Trust.Store.all()
    base = %{high: 0, medium: 0, low: 0, unrated: 0}

    Enum.reduce(all_tools, base, fn tool, acc ->
      band =
        case Map.fetch(scored, tool.id) do
          {:ok, score} -> score_to_band(score)
          :error -> :unrated
        end
      Map.update!(acc, band, &(&1 + 1))
    end)
  catch
    :exit, _ -> %{high: 0, medium: 0, low: 0, unrated: 0}
  end
end

defp score_to_band(score) when score >= 0.8, do: :high
defp score_to_band(score) when score >= 0.5, do: :medium
defp score_to_band(_), do: :low
```

### `lib/shem/tui/views/dashboard.ex`

Replace:

```elixir
label(content: "Lab: idle", ...)
```

With:

```elixir
label(
  content: "Trust: #{counts.high} high  #{counts.medium} med  #{counts.low} low  #{counts.unrated} unrated",
  color: color(:magenta)
)
```

Where `counts` comes from `model.trust_counts`.

### `lib/shem/tui/views/interactive.ex`

Add a new `render_turn_card/1` clause between the nil and active-agent clauses:

```elixir
defp render_turn_card(%{agent_view: nil, command_output: output}) when not is_nil(output) do
  panel(title: "Shem // Interactive · Output", color: color(:cyan)) do
    for line <- String.split(output, "\n") do
      label(content: line, color: color(:white))
    end
  end
end
```

## Files

| Action | File |
|---|---|
| Modify | `lib/shem/trust/store.ex` |
| Modify | `lib/shem/tui/command_dispatch.ex` |
| Modify | `lib/shem/tui/app.ex` |
| Modify | `lib/shem/tui/views/dashboard.ex` |
| Modify | `lib/shem/tui/views/interactive.ex` |

## Tests

- `test/shem/trust/store_test.exs` — add cases for `entry/1`: known tool returns full map, unknown returns `{:error, :unrated}`
- `test/shem/tui/command_dispatch_test.exs` — add cases for `/tools` → `{:tools}`, `/trust foo` → `{:trust, "foo"}`, `/trust` → error
- `test/shem/tui/app_test.exs` — add cases for `{:tools}` and `{:trust, name}` producing correct `command_output`; `safe_trust_counts/0` band bucketing

## Non-goals

- No trust surfacing for MCP or builtin tools
- No new TUI views or panels — output uses the existing turn card slot
- No pagination for `/tools` — if the list is long, it truncates naturally via Ratatouille's label rendering
