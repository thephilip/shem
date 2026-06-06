# Phase 10c: Trust-Gated Execution — Design

## Goal

Prevent agents from invoking Lab tools that have been hardened and scored poorly. The trust band already exists on every manifest entry (from Phase 10b); this phase adds the execution gate that acts on it.

## Scope

Only Lab tools (source: `{:lab, id}`) are gated. Builtin and MCP tools bypass the check entirely — they have no hardening history and no meaningful trust score to act on.

## Behavior

| Trust band | Gate enabled | Gate disabled |
|---|---|---|
| `:high` / `:medium` / `:unrated` | allow | allow |
| `:low` | block | allow |
| `:builtin` / `:external` | always allow | always allow |

`:unrated` tools are allowed because they have never been hardened — they are not known-bad. Hardening is already queued at graduation time via the existing post-graduation trigger.

A blocked call returns `{:error, "tool blocked (trust: low)"}`. This surfaces through the existing `execute_tool_calls` path in `Agent.Server` as a `agent_tool_result` event with content `"Error: tool blocked (trust: low)"`. No new event types are needed.

## Architecture

### Gate placement

The gate lives in `ToolDispatch.execute/2`. This function already receives the full manifest, which carries `trust:` on every entry. When the matched entry has source `{:lab, id}`, trust is checked before dispatching.

`find_source/2` is removed — it is only used inside `execute/2`, and the refactor inlines its logic while adding trust access.

### Config

```elixir
# config/config.exs
config :shem, trust_gate_enabled: true

# config/test.exs
config :shem, trust_gate_enabled: false
```

The test default is `false` so existing tests against unrated tools are not broken by the gate.

### Implementation sketch

```elixir
def execute(%{tool: name, args: args}, manifest) do
  case Enum.find(manifest, &(&1.name == name)) do
    nil                                     -> {:error, "unknown tool: #{name}"}
    %{source: :builtin}                     -> dispatch_builtin(name, args)
    %{source: {:mcp, server}}               -> dispatch_mcp(server, name, args)
    %{source: {:lab, id}, trust: trust}     ->
      if gate_blocks?(trust),
        do:   {:error, "tool blocked (trust: #{trust})"},
        else: dispatch_lab(id, args)
  end
end

defp gate_blocks?(:low), do: Application.get_env(:shem, :trust_gate_enabled, true)
defp gate_blocks?(_),    do: false
```

## Files

| Action | File |
|---|---|
| Modify | `lib/shem/agent/tool_dispatch.ex` |
| Modify | `config/config.exs` |
| Modify | `config/test.exs` |
| Modify | `test/shem/agent/tool_dispatch_test.exs` |

## Tests

New cases added to `test/shem/agent/tool_dispatch_test.exs`. `Trust.Store.record/2` is used in setup to seed scores.

- `:low` tool is blocked when `trust_gate_enabled: true`
- `:low` tool is allowed when `trust_gate_enabled: false`
- `:unrated` tool is allowed when gate enabled
- `:medium` and `:high` tools are allowed when gate enabled
- builtin tool is never blocked regardless of config

## Non-goals

- No automatic re-hardening on block — that is triggered at graduation time and via `/redteam`
- No changes to manifest enrichment — trust bands appear unconditionally regardless of gate setting
- No gating of MCP or builtin tools
