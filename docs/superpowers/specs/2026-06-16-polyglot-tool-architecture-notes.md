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

### 5. Non-Elixir tools use persistent BEAM Ports, not fresh processes

Rejected: `run_shell` (fresh process per call) for runtime invocation of graduated tools.
Reason: agents call tools repeatedly in a ReAct loop — `fork/exec` + container startup per call is hundreds of milliseconds each time. BEAM Ports are designed for exactly this: a supervised OS process started once, handling N calls with near-zero per-call overhead.

**Decision:** Graduated non-Elixir tools get a BEAM Port per tool (started on first use, kept alive, restarted on crash via a `PortPool` supervisor). Python processes send/receive JSON lines on stdin/stdout.

Graduation (testing) still uses a fresh container per graduation — that happens rarely, startup cost is acceptable.

### 6. Elixir tools stay in-BEAM

Rejected: running Elixir graduated tools in containers.
Reason: the BEAM compilation model + StreamData + adversarial hardening IS the Elixir isolation story. Containerizing Elixir tools would destroy zero-overhead function calls, OTP access, hot loading, and the entire trust pipeline. The asymmetry is justified by runtime model, not language preference.

### 7. `Tool` struct gets a `runtime:` union field

`module:` is currently `@enforce_keys` — meaningless for non-Elixir tools.

**Decision:** Replace with `runtime:` union:
- `{:beam, ModuleName}` — Elixir tools (in-process call)
- `{:port, command}` — non-Elixir tools (BEAM Port, JSON in/out)

Makes dispatch branching explicit and self-documenting. `module:` removed from enforce_keys; `runtime:` added.

### 8. Phases may be split if scope is too large

The polyglot tool runtime (Port pool, GraduationGate router, Tool struct change, write_tool extension) and the python_toolsmith preset may be separate phases if the combined scope is too large for one implementation plan.

### 9. Pre-existing bug: metadata lost on restart — fix in 43a

`Workspace.graduate` writes only `tool.source` to `graduated/{id}.ex`. `scan_graduated` in `Lab.Registry` reconstructs `%Tool{}` structs from those files via regex — it has no access to `description`, `schema`, `constraints`, `test_source`, or `runtime`. All metadata is lost on every node restart.

Symptom: Phase 42 graduated tools reappear in `build_manifest` with `"graduated tool: <name>"` instead of their description after a restart.

**Fix in 43a:** `Workspace.graduate` writes a companion `graduated/{id}.json` manifest alongside the source, containing all metadata. `scan_graduated` reads the manifest when present; falls back to source-regex extraction for legacy `.ex`-only tools (backwards compat). Python tools write `graduated/{id}.py` + `graduated/{id}.json`.

### 10. Three dispatch sites use `tool.module` — all need updating

- `lib/shem/agent/tool_dispatch.ex:415` — `tool.module.run(args)` in `dispatch_lab`
- `lib/shem/mcp/handlers/invoke_tool.ex:19` — `tool.module.run(args)`
- `lib/shem/mcp/handlers/invoke_tool.ex:27` — `ensure_loaded(%{module: module, source: source})` pattern-matches the field directly

All three must branch on `tool.runtime`: `{:beam, mod}` → existing path; `{:port, cmd}` → PortPool dispatch.

### 11. `scan_graduated` migration shim lives in `scan_graduated`, not in a deserializer

Tools are stored as source files, not serialized structs. The backwards-compat shim for the `module:` → `runtime:` rename lives in `scan_graduated`: for `.ex` files with no manifest, synthesize `runtime: {:beam, extracted_module}` instead of `module: extracted_module`.

## Open Questions (to address in the Phase 43 spec)

- BEAM Port lifecycle: one Port per tool (global, shared across agents) or one Port per tool per agent session? Global is simpler; per-session is safer for isolation.
- `write_tool` schema: `source` + `test_source` field names are language-agnostic enough to keep. `language:` defaults to `"elixir"` for full backwards compat.
- GraduationGate router: single module with language-tagged function clauses, or separate `GraduationGate.Python` / `GraduationGate.Elixir` modules?
- Trust model for Python tools: StreamData is Elixir-specific. Python equivalent could be Hypothesis (property testing library). Or trust is seeded at 0.5 (same as Elixir tools without property tests) and earned through adversarial hardening. Decision deferred.
- Container image config per language: `executor_image_python: "python:3.12-slim"` alongside existing `executor_image`.
- Backwards compat for existing `Tool` structs: existing graduated Elixir tools have no `runtime:` field in DETS/Mnesia. Migration strategy needed (default to `{:beam, module}` on read).

## Related External Feedback

From a project review (2026-06-16):
- "Tool authoring story for non-Elixir devs is underspecified" — the `graduate_tool` mechanism only handles Elixir today
- "Bring your own binary/script tool registration API" needed — analogous to MCP tool definitions
- Python SDK is buried and minimal; JS/TS SDK doesn't exist
- Tool marketplace is the network-effect flywheel — needs manifest-portable, signable artifacts
- Migration adapters (LangChain/CrewAI/AutoGen) would lower switching cost dramatically

These gaps inform the polyglot tool design: the manifest format, SDK story, and marketplace all converge on the same primitive — a language-agnostic tool definition that any developer can register, not just Elixir developers using the graduation gate.
