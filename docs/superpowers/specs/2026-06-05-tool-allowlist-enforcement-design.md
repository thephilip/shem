# Design: Tool Allow-List Enforcement

**Date:** 2026-06-05  
**Status:** Approved

## Problem

`ToolDispatch.build_manifest/1` filters MCP tools against `Config.tools` but applies `@builtins` and Lab tools unconditionally. The `explore` preset's `tools: ["read_file", "list_dir", "shell"]` restriction is system-prompt-only — the LLM is told not to use `write_file`, but `write_file` appears in the manifest and is fully executable if called.

## Goal

Make `Config.tools` the single source of truth for what an agent can invoke. A tool not in the allow-list must not appear in the manifest.

## Convention (unchanged)

- `tools: []` — allow all (`:all` maps to `[]` in `start_with_preset/2`)
- `tools: ["read_file", ...]` — exact allow-list; only these tools appear in the manifest

## Design

### Enforcement layer

`build_manifest/1` is the right and only place to enforce the allow-list. The manifest is the agent's view of available tools — it drives the LLM prompt. If a tool isn't in the manifest, the LLM never sees it. If the LLM calls it anyway, `find_source/2` returns `nil` and `execute/2` returns `{:error, "unknown tool: ..."}`. No changes needed to `execute/2`, `Server`, or `Turn`.

### Changes to `build_manifest/1`

Apply the allow-list filter uniformly across all three tool categories:

**Builtins:** Filter `@builtins` against `allowed_tools` when non-empty. `list_tools` is always injected back regardless of the allow-list — it is a pure meta-capability (shows what is in the manifest; cannot take actions), and blocking it produces confusing `unknown tool` failures with no security benefit. The existing `execute/2` clause for `list_tools` already handles it without a manifest lookup, making always-present semantics consistent.

**Lab tools:** Filter by `tool.name` against `allowed_tools` when non-empty.

**MCP tools:** Already filtered correctly — no change.

Helper used for all three categories:

```elixir
defp filter_by_allowed(tools, [], _name_fn), do: tools
defp filter_by_allowed(tools, allowed, name_fn), do: Enum.filter(tools, &(name_fn.(&1) in allowed))
```

### `explore` preset

No change. The system prompt instruction "Do not use write_file or write_tool" becomes redundant enforcement rather than advisory-only. `tools: ["read_file", "list_dir", "shell"]` now actually restricts the manifest.

## Tests

Two new tests in `ToolDispatchTest`:

1. `build_manifest/1` with a restricted allow-list returns only listed builtin names (plus `list_tools` implicitly)
2. `build_manifest/1` with a restricted allow-list excludes Lab tools whose names are not in the list

Existing `"built-in entries have :builtin source"` test uses `@config` with `tools: []` (allow-all) — passes unchanged.

## Out of scope

- K8s executor routing for `shell` (tracked as `# TODO(phase-9b)`)
- Unit test for `App.update/2` Enter-key branch (requires running supervisor)
- Runtime registration of MCP servers (deferred to Phase 5/6)
