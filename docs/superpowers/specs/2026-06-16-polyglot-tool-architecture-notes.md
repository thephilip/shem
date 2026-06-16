# Polyglot Tool Architecture — Decision Notes
_2026-06-16 — captured mid-brainstorm, not yet a full spec_

## Context

After Phase 42 (elixir_toolsmith), the question arose: how do we extend the self-evolution loop to Python and other languages? An external review of the project surfaced a sharper framing: the real gap is a **"bring your own binary/script" tool registration API** — something like a manifest that wraps any executable as a Shem tool, analogous to how MCP tool definitions work.

## Decisions Made

### 1. `write_tool` becomes the unified polyglot primitive

`write_tool` should NOT remain Elixir-specific. Having `write_tool` for Elixir and a separate `write_external_tool` for everything else is language dogma — it tells agents that Elixir tools are "real" and others are "external." This violates the project's own principles.

**Decision:** `write_tool` gains a `language:` field (default `"elixir"`) that routes to the appropriate graduation backend:
- `"elixir"` → BEAM compilation, in-process hot loading, StreamData property tests (preserved as a capability/performance optimization, not a privilege)
- `"python"` → Python subprocess, JSON in/out, pytest-style gate
- `"shell"` / others → bare executable, minimal gate

The BEAM path exists because in-process execution is faster and enables OTP access from within the tool — a capability argument, not a language preference argument.

**Cost:** The Phase 42 `write_tool` schema (just shipped) needs a `language:` field added and some fields made conditionally required. Worth fixing while the API is new.

### 2. Python tool calling convention: JSON stdin → JSON stdout

- Args passed as a JSON object on stdin
- Result returned as a JSON object on stdout (or a JSON-encoded scalar)
- Language-agnostic: the same contract works for Rust, Go, JS, shell scripts
- Every language has a standard JSON library; no third-party deps required
- Aligns with what the LLM already produces when calling tools (the `args` map is already JSON-shaped)

YAML was considered (it's what Shem's config uses) but rejected for inter-process data exchange: JSON is the standard for structured data between processes, YAML adds parsing complexity for no benefit here.

### 3. `python_toolsmith` is the first instance of `<language>_toolsmith`

The naming convention (`<language>_toolsmith`) is already established. `python_toolsmith` produces:
- A Python script implementing the tool (stdin JSON → stdout JSON)
- A test file (pytest)
- Calls `write_tool(language: "python", source: ..., test_source: ..., description: ..., schema: ...)`

### 4. Manifest-based "bring your own binary" registration

For developers who already have a compiled binary or existing script, there should be a first-class path that doesn't require the agent to write and graduate code. This is a `shem.tool.json` manifest (name TBD) that wraps any executable:

```json
{
  "name": "my_tool",
  "description": "...",
  "command": ["./my_binary", "--json"],
  "schema": { "type": "object", ... },
  "language": "shell"
}
```

This is analogous to MCP tool definitions. The BEAM Port mechanism (mentioned in the blueprint) is relevant here for long-running tools that shouldn't be re-spawned per call.

**Status:** Not yet designed in detail. Needs its own brainstorm. Relevant to the tool marketplace and SDK story.

## Open Questions (to address in the Phase 43 spec)

- `write_tool` schema shape for non-Elixir: are `source` + `test_source` still the right field names? (They are language-agnostic enough.)
- GraduationGate router: how does it detect/dispatch by language? New `Shem.Lab.GraduationGate.Python` module, or a single gate with language-tagged clauses?
- `Tool` struct: add `language:` field (`:elixir` default for backwards compat with existing graduated tools).
- `dispatch_lab` branching: Elixir → `tool.module.run(args)`; Python → `run_shell("python3 -c ...")` with JSON in/out.
- Trust model for non-Elixir tools: StreamData property tests are Elixir-specific. What's the equivalent signal for Python tools? (pytest property tests via Hypothesis?)
- BEAM Port vs `run_shell` for Python tools: `run_shell` spawns a new process per call; BEAM Ports can keep a process alive across calls. Which is right for Python tools?

## Related External Feedback

From a project review (2026-06-16):
- "Tool authoring story for non-Elixir devs is underspecified" — the `graduate_tool` mechanism only handles Elixir today
- "Bring your own binary/script tool registration API" needed — analogous to MCP tool definitions
- Python SDK is buried and minimal; JS/TS SDK doesn't exist
- Tool marketplace is the network-effect flywheel — needs manifest-portable, signable artifacts
- Migration adapters (LangChain/CrewAI/AutoGen) would lower switching cost dramatically

These gaps inform the polyglot tool design: the manifest format, SDK story, and marketplace all converge on the same primitive — a language-agnostic tool definition that any developer can register, not just Elixir developers using the graduation gate.
