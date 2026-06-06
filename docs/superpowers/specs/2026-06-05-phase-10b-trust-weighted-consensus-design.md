# Design: Phase 10b — Trust-Weighted Agent Consensus

**Date:** 2026-06-05  
**Status:** Approved

## Goal

Build a trust scoring system for graduated tools, fed automatically by Phase 10a hardening outcomes. Trust scores surface in the tool manifest so agents can reason about tool reliability when choosing which tool to call.

---

## Architecture

```
HardeningJob.finish/3
  └─ Trust.Store.record(tool_id, %{outcome:, rounds:})

Trust.Store (GenServer, DETS-backed)
  └─ score/1 → float 0.0–1.0
  └─ record/2 → updates score with recency-weighted blend
  └─ all/0 → full score map

ToolDispatch.build_manifest/1
  └─ enriches each Lab tool entry with trust: :high | :medium | :low | :unrated
  └─ builtins → trust: :builtin
  └─ MCP tools → trust: :external
```

---

## Trust Store

`Shem.Trust.Store` — GenServer backed by DETS at `~/.config/shem/trust.dets`.

### State schema (per tool_id)

```elixir
%{
  tool_id: String.t(),
  score: float(),
  last_updated: DateTime.t(),
  hardening_count: non_neg_integer()
}
```

### Public API

```elixir
@spec record(String.t(), %{outcome: atom(), rounds: non_neg_integer()}) :: :ok
@spec score(String.t()) :: {:ok, float()} | {:error, :unrated}
@spec all() :: %{String.t() => float()}
```

---

## Score Formula

On each `record/2` call:

```elixir
outcome_score =
  case {outcome, rounds} do
    {:clean, 1}    -> 1.0
    {:clean, n}    -> max(1.0 - (n - 1) * 0.15, 0.3)
    {:max_rounds_reached, _} -> 0.2
    {:error, _}    -> 0.1
  end

recency_weight = 0.7

new_score =
  case prior_score do
    nil   -> outcome_score
    prior -> recency_weight * outcome_score + (1 - recency_weight) * prior
  end
  |> max(0.0) |> min(1.0)
```

First hardening sets the score directly. Each subsequent hardening blends at 70% new / 30% prior — recent results matter more.

### Trust bands

| Band | Score range |
|------|-------------|
| `:high` | ≥ 0.8 |
| `:medium` | ≥ 0.5 |
| `:low` | < 0.5 |
| `:unrated` | never hardened |

---

## Manifest Integration

`build_manifest/1` adds `trust:` to each tool entry:

```elixir
# Lab tools
%{name: tool.name, description: "...", source: {:lab, id}, trust: :high}

# Builtin tools (read_file, shell, etc.)
%{name: "read_file", description: "...", source: :builtin, trust: :builtin}

# MCP tools
%{name: "...", description: "...", source: {:mcp, server}, trust: :external}
```

---

## HardeningJob Integration

In `finish/3`, before appending `:hardening_completed`:

```elixir
Trust.Store.record(state.tool_id, %{outcome: outcome, rounds: state.round})
```

---

## Modified Modules

| Module | Change |
|--------|--------|
| `lib/shem/trust/store.ex` | New — GenServer + DETS backend |
| `lib/shem/adversarial/hardening_job.ex` | Call `Trust.Store.record/2` in `finish/3` |
| `lib/shem/agent/tool_dispatch.ex` | Add `trust:` field to manifest entries |
| `lib/shem/application.ex` | Add `Trust.Store` child before `Adversarial.Supervisor` |
| `config/test.exs` | No guard needed — Store is lightweight |

---

## Testing Strategy

**`Trust.Store`:**
- `record/2` → `score/1` round-trips correctly
- Recency weighting: two records, verify blend
- First hardening sets score directly (no prior)
- DETS persistence: write, restart GenServer, read back
- `all/0` returns map of all recorded tool_ids

**`ToolDispatch`:**
- Manifest entry for hardened tool includes correct trust band
- Unrated tool (no hardening record) shows `:unrated`
- Builtins show `:builtin`, MCP tools show `:external`

**`HardeningJob`:**
- After clean pass, `Trust.Store.score(tool_id)` returns a score ≥ 0.8
- After `max_rounds_reached`, score ≤ 0.3

---

## Out of Scope

- Task routing (Phase 10c) — picking agent config based on trust before task starts
- TUI trust dashboard — surfacing scores in the Interactive view
- Per-agent trust (agent inherits weighted avg of tools it called) — after scores have real signal
- Trust decay over inactivity (time-based) — deferred
