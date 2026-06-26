# Future Work: Container-Based Polyglot Tool Execution

_Status: deferred. Documented so it isn't lost. Origin: the user's original
project vision — polyglot development should happen in containers (Podman), which
makes it safer and removes per-language host dependencies._

## Why this exists
Shem's North Star is **polyglot** agent orchestration, but today the real surface
is "Elixir + Python":
- `Tool.runtime :: {:beam, module} | {:port, path}` — two runtimes.
- The `:port` path is Python-shaped: `Workspace.build_stdio_wrapper/1`
  (`workspace.ex:86`) emits a Python `__main__` stdin loop, and `PortPool`
  defaults `executable: "python3"`.
- Inconsistency to resolve: Python tools are **tested** in a container
  (`GraduationGate.Python` → `Executor.Backend.Container.run_shell`,
  `mounts: [{tmp_dir, "/workspace"}]`) but **run** on the host (PortPool spawns
  `python3` directly via `Port.open`). Tested-in-container, run-on-host is a
  trust + reproducibility gap.

The user's insight: run tool *runtimes* in containers. One dependency (Podman)
replaces N host language installs (deno, node, go, ruby…), and the container
boundary is a real sandbox for untrusted tool code.

## Honest sizing — this is NOT just `executable` plumbing
The execution layer is *partly* ready and partly new:

**Ready:**
- `PortPool` already parameterizes `executable` and speaks line-delimited JSON
  over stdio (`port_pool.ex:109`). Swapping `python3` → another interpreter on the
  host is genuinely trivial.
- `Executor.Backend.Container` + `run_shell` + `mounts` exist and are proven by
  Python graduation.

**New (the real work):**
- `run_shell` is **one-shot** (run pytest, return result). Tool *invocation* needs
  a **persistent stdio process** — PortPool keeps workers alive piping JSON lines
  request-by-request. Persistent stdio *into* a container
  (`podman run -i --rm <img> <interp> <script>` as the PortPool executable, kept
  open) is new plumbing, not a config flag.
- Per-language stdio wrapper generators (a TS/Deno loop, a bash loop, …) to
  replace the Python-only `build_stdio_wrapper/1`.
- Manifest gains an `executable` / `image` field, plumbed through
  `Workspace.build_manifest` → `Registry.build_tool_from_manifest` → PortPool.
- Graceful degrade: a tool whose interpreter/image is unavailable is
  skipped-with-log, never a boot crash.

## Two sub-deliverables (sequence)
1. **Container-run port tools** — move `:port` execution into a container
   (persistent stdio), close the tested-vs-run gap, add `image`/`executable` to the
   manifest. Python moves run-in-container too. No new languages yet.
2. **New-language GraduationGate** — let *agents author* non-Python port tools
   (TS/Deno first). Builds on #1's wrapper + manifest plumbing. This is what makes
   "polyglot" real on the authoring side, not just the bundling side.

## Showcase tool
**`sanitize_untrusted`** (TypeScript/Deno) — port of **Plunger**'s sanitizer
(`../plunger/plunger.ts`): strip invisible Unicode (U+E0000–U+E007F), flag known
prompt-injection patterns, wrap untrusted web content in `<untrusted>` tags. A
genuinely useful guard for any agent that fetches web content, and the first
real non-Elixir/non-Python bundled tool. Becomes a seed tool (see
`2026-06-22-bundled-seed-tools-design.md`) once #1 lands.

## Relation to other deferred ideas
- Supersedes / absorbs the K8s-executor idea (`project-phase4b-k8s-idea` in
  auto-memory): same "containers as polyglot Lab backend," Podman-first instead of
  K8s-first. K8s becomes a later executor backend swap, not the entry point.
- Aligns with `project-container-workflow` (coding sessions in containers).

## Trigger to build
When the user wants agents to author tools in a third language, OR wants the
tested-vs-run reproducibility gap closed. Until then: Elixir + Python on host is
the working surface.

## Update 2026-06-25 — this is now "Phase B" (P2), and the surface is wider
The runtime surface grew to **four** languages: Elixir (BEAM), Python + JavaScript
(Deno, deny-all sandboxed) + Go — both Python and Go run **on the host** (no runtime
sandbox); only JS is sandboxed. This doc is now the agreed **Phase B**: run all `:port`
runtimes (Python, JS, Go) in containers to close the host-execution gap uniformly. Decided
during the Go-runtime brainstorm (Go shipped on-host as Phase A). Open sub-fork to brainstorm
first: one-shot container per call (simple, no pooling) vs persistent container per tool
(pooled, lifecycle mgmt). Priority/context: `docs/future-work/2026-06-25-runtime-followups.md`
(note: the tool-packs polyglot bug is P1, ahead of this).
