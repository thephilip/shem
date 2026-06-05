# Design: Phase 10a — Adversarial Self-Improvement Loop

**Date:** 2026-06-05  
**Status:** Approved

## Goal

Automatically harden graduated tools by running a red team agent against them. When the red team finds failures, a target agent patches the tool. The loop repeats until the tool survives a full red team pass or a configurable round ceiling is reached. All activity is logged to the EventLog and visible in the TUI.

---

## Prerequisite: Thinking Token Stripping

`Turn.step/4` currently passes raw LLM content straight to `parse_response/1`. Qwen3 (and other reasoning models) emit `<think>...</think>` blocks before their actual response. These blocks can contain JSON-like structures that confuse tool call extraction.

**Fix:** Add `strip_thinking/1` to `Turn`, called in `step/4` after `LLM.complete/1` returns and before `parse_response/1`:

```elixir
defp strip_thinking(content) do
  Regex.replace(~r/<think>.*?<\/think>/s, content, "") |> String.trim()
end
```

New tests in `turn_test.exs`: content with `<think>` block stripped correctly; content without block unchanged.

---

## Architecture

```
GraduationGate.run/2
  └─ on {:ok, tool} → Adversarial.start_hardening(tool.id)   [fire & forget]

Adversarial.Supervisor (DynamicSupervisor)
  └─ HardeningJob (GenServer, :temporary) × N active jobs

HardeningJob loop:
  init
    └─ log :hardening_started
    └─ send :run_round

  :run_round
    └─ start RedTeam Agent.Server (run_code + read_file)
    └─ await RedTeam
    └─ parse result
         ├─ :clean           → log :hardening_completed (outcome: :clean), done
         └─ {:failures, msg} → start Target Agent.Server (write_tool + run_code)
                               await Target
                               increment round
                               round >= max_rounds?
                                 ├─ yes → log :hardening_completed (outcome: :max_rounds_reached), done
                                 └─ no  → send :run_round
```

---

## New Modules

### `Shem.Adversarial`

Public API:

```elixir
@spec start_hardening(tool_id :: String.t()) :: {:ok, job_name :: String.t()} | {:error, term()}
@spec status(job_name :: String.t()) :: {:ok, map()} | {:error, :not_found}
```

`start_hardening/1` is a no-op (returns `{:ok, :disabled}`) when `Adversarial.Supervisor` is not running — no test config required.

### `Shem.Adversarial.Supervisor`

DynamicSupervisor. Added to `Application` children before `AgentSupervisor`. Guards: always started unless `config :shem, start_adversarial: false`.

### `Shem.Adversarial.HardeningJob`

GenServer. `:temporary` restart strategy — a crashed job does not restart and does not affect the supervisor.

**State:**
```elixir
%{
  tool_id: String.t(),
  tool_name: String.t(),
  round: non_neg_integer(),
  max_rounds: pos_integer(),
  session_id: String.t(),
  status: :running | :done
}
```

**Agent configs built per round** using current tool source from `Lab.Registry.lookup_by_name/1`.

**Await timeout:** `adversarial_agent_timeout_ms` (default `300_000`). Timeout → `:hardening_completed` with `outcome: :error`.

---

## Agent Prompts

### Red Team Agent

```
You are a red team agent. Your job is to find failures in the Elixir tool "#{tool_name}".
Source:
#{tool_source}

Write StreamData property tests and targeted edge case tests using run_code.
Each test must call the tool's run/1 function directly.

When done, respond with exactly one of:
FAILURES_FOUND: <one-line summary of what broke>
NO_FAILURES_FOUND
```

Tools: `["run_code", "read_file"]`, `max_turns: 10`

### Target Agent

```
You are a tool repair agent. The tool "#{tool_name}" has a known failure:
#{failure_summary}

Current source:
#{tool_source}

Rewrite the tool to fix this failure. Use write_tool to graduate the new version.
The new version must pass its own tests before graduating.
```

Tools: `["write_tool", "run_code"]`, `max_turns: 10`

---

## Result Extraction

`HardeningJob` reads the red team agent's final assistant message (from its EventLog session) and scans for the structured marker:

```elixir
defp parse_red_team_result(answer) do
  cond do
    String.contains?(answer, "FAILURES_FOUND:") ->
      summary = answer |> String.split("FAILURES_FOUND:") |> List.last() |> String.trim()
      {:failures, summary}
    String.contains?(answer, "NO_FAILURES_FOUND") ->
      :clean
    true ->
      :clean  # ambiguous → treat as clean to prevent infinite loops
  end
end
```

---

## Modified Modules

### `Shem.Lab.Registry`

Add `lookup_by_name(name :: String.t()) :: {:ok, Tool.t()} | {:error, :not_found}`.  
Scans the ETS table for a tool whose `name` field matches. Used by `HardeningJob` to get current source at the start of each round.

### `Shem.Lab.GraduationGate`

After `{:ok, tool}` return, fire and forget:

```elixir
Shem.Adversarial.start_hardening(tool.id)
```

### `Shem.Agent.Turn`

Add `strip_thinking/1`. Call it in `step/4` after `LLM.complete/1` and before `parse_response/1`.

### `Shem.TUI.CommandDispatch`

Add clause:

```elixir
"/redteam " <> rest -> {:redteam, String.trim(rest)}
```

### `Shem.TUI.App`

Route `{:redteam, name}` — call `Lab.Registry.lookup_by_name(name)`, then `Adversarial.start_hardening(tool.id)`. Unknown tool: surface error in prompt row.

### `Shem.Application`

Add `{Shem.Adversarial.Supervisor, []}` to children, before `AgentSupervisor`.

---

## Event Types

All appended to `HardeningJob`'s own EventLog session.

| Type | Payload |
|------|---------|
| `:hardening_started` | `%{tool: name, tool_id: id, max_rounds: n}` |
| `:hardening_round_started` | `%{round: n, tool: name}` |
| `:hardening_attack_complete` | `%{round: n, failures_found: bool, summary: string \| nil}` |
| `:hardening_patch_complete` | `%{round: n, tool: name}` |
| `:hardening_completed` | `%{tool: name, rounds: n, outcome: :clean \| :max_rounds_reached \| :error}` |

---

## Config

```elixir
# dev.exs / config.exs
config :shem,
  adversarial_max_rounds: 5,
  adversarial_agent_timeout_ms: 300_000

# test.exs
config :shem, start_adversarial: false
```

---

## Testing Strategy

All `HardeningJob` tests use `StubTransport` — no real LLM calls.

| Test | Scenario |
|------|----------|
| Clean pass round 1 | `:hardening_completed`, `outcome: :clean`, `rounds: 1` |
| Failure round 1, clean round 2 | 2 rounds, `outcome: :clean` |
| Failures persist through max rounds | `outcome: :max_rounds_reached` |
| Ambiguous red team response | Treated as `:clean` |
| Agent timeout | `outcome: :error` |

`Lab.Registry.lookup_by_name/1`: found, not found.  
`Turn` thinking-token stripping: with block, without block.  
`CommandDispatch`: `/redteam my_tool` → `{:redteam, "my_tool"}`.

---

## Out of Scope

- Phase 10b: Trust-Weighted Agent Consensus
- K8s executor routing for `shell` (Phase 9b TODO)
- Hardening status surfaced in `Lab.Registry` metadata (can be added later)
- Parallel hardening jobs for the same tool (serialised by tool_id — first wins)
