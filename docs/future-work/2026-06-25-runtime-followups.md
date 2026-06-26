# Runtime Follow-ups (after Go = 4th runtime, 2026-06-25)

Prioritized backlog surfaced by the JS + Go runtime work and its validation passes.
P1 = correctness bug in shipped code; P2 = strategic direction; P3 = deeper gap;
P4 = hygiene.

## P1 (front door) — CLI startup is broken/confusing (`shem start`, `--headless`, TUI gone)

The `shem` launcher (`~/.local/bin/shem`, installed by `install.sh`) dispatches to the OTP
release binary. Traced 2026-06-25 — a cluster of real bugs in the **first-run experience**,
which gates adoption ("useful AND used" dies at a broken start). Symptoms → root causes:

| Symptom | Root cause |
|---|---|
| `shem start` "just starts the webui", no TUI | The launcher runs the release **`start`** verb (`exec $BIN start`) = **detached daemon** (`run_erl`, no TTY). The app's supervision tree boots the HTTP/MCP server on :4000, but a TUI can't attach to a daemon. |
| **TUI is gone entirely** | TWO causes, either alone is fatal: (1) **releases run `prod` config → `start_tui: false`** (`config/prod.exs:3`), so `application.ex:85` `tui_children()` returns `[]` — the TUI process is never started unless the user's YAML has a `tui` key. (2) Even if started, a detached daemon has no TTY → `Ratatouille.Window.init` fails `{:error, -2}` (seen in `mix run` under a pipe). |
| `shem start --headless` "does almost nothing" | `SHEM_NO_TUI=1 … $BIN start` → server runs **in the background, detached, with no output** — no "serving on :4000" banner, terminal returns immediately. It IS running; it just gives zero feedback. Contrast `mix shem.serve`, which runs **foreground** and prints the endpoints. |
| `shem --headless` (no `start`) does nothing | Not matched by the `start)` case → falls to `*)` → prints "unknown command '--headless'" + help, exits 1. `--headless` only works as `shem start --headless`. |
| Can't cleanly stop it | The launcher has **no `shem stop`** — once daemonized there's no CLI way to stop the node. |

**Fix direction (a brainstorm/spec, not a one-liner — it's the front door):**
- `shem start` (TUI) → run the release **`foreground`** verb (TUI owns the terminal; `console` would fight it for stdin), AND make `start_tui` default **true** for an interactive/TTY start (e.g. launcher sets a `SHEM_TUI=1`, or `runtime.exs` defaults `start_tui: true` when not `--headless` and `[ -t 1 ]`). Today prod's `false` silently wins.
- `shem start --headless` → run **foreground** like `mix shem.serve` and print the endpoints banner; add an explicit `--daemon` for background use, and only daemonize when asked.
- `shem --headless` → alias to `shem start --headless`.
- Add **`shem stop`** (release `stop`) and make sure `shem status` reports the daemon.
- First-run experience (North Star Phase 28) effectively regressed for the release/TUI path — verify end-to-end on an actual installed release, not `mix`.

## P1 — Tool packs are Python-hardcoded (CONFIRMED BUG, ships broken for JS/Go)

Same bug class as the registry reload bug fixed during the Go work
(`build_tool_from_manifest` read `#{id}.py`). Tool packs never got the layout/language
generalization:

- `lib/shem/lab/pack.ex:95` — `ext = if language == "elixir", do: "ex", else: "py"`.
  A JavaScript tool's source is `.ts` and a Go tool's is `tool.go` inside a dir, so
  pack **install** reads the wrong path → empty/missing source.
- `lib/shem/lab/pack.ex:148` — export/copy iterates a fixed suffix list
  `[".json", ".ex", ".py", "_runtime.py"]`. Misses `.ts`, `.go`, `_runtime.ts`, and Go's
  `#{id}_runtime/` **directory** entirely.

**Impact:** JS packs (a shipped feature) and Go packs are broken. **Fix:** reuse the
`Shem.Lab.Languages.{ext/1, layout/1}` generalization already in `Workspace`/`registry` —
resolve source path and copy-set by language/layout; copy the `_runtime` dir for `:dir`
tools (mirror the layout-aware `quarantine/2`). Needs a **validation pass** first (pack
install/uninstall/export of a JS and a Go tool, round-tripped through a real git repo).
This is the highest-value next task.

## P2 — Phase B: run ALL `:port` runtimes in containers

See `docs/future-work/2026-06-22-container-polyglot.md`. Go and Python tools currently run
**on the host** (no runtime sandbox); only JS/Deno is deny-all sandboxed. Phase B runs the
runtimes (not just the graduation gate) in containers, closing the sandbox gap for
Python + JS + Go uniformly — the user's container-first direction. Decided during Go
brainstorming as the explicit next phase after Go-on-host. Has its own sub-fork
(one-shot container per call vs persistent container per tool — needs a brainstorm).

## P3 — Distributed `:port`-tool artifact locality

A `:port` tool (JS/Go) writes its runtime file/dir to the **local** node's lab_dir, and the
manifest persists an absolute path. After SIGTERM evacuation or on a peer node, that path
doesn't exist → the tool can't run off its origin node. Affects all `:port` runtimes, not
just Go. Deeper design question (how do port-tool artifacts replicate across the mesh —
ship bytes in the checkpoint? re-graduate on demand? content-addressed store?). Largely
mooted by P2 if runtimes move into shared/container storage — sequence after Phase B.

## P4 — Pre-existing seed-dependent TUI flake

A single TUI test fails on some no-seed full runs; green under `--seed 0` and on re-run.
NOT introduced by the JS/Go work — observed across multiple sessions. Low priority, but
recurring enough to harden separately (likely a Ratatouille/Window init race under load;
the runtime supervisor already disables the TUI under `mix shem.serve`). Track until it
either stops surfacing or someone roots it out.

## Maintenance — refresh the graphify graph (not blocking)

`graphify-out/graph.json` is from 2026-06-22, predating BOTH the JS and Go runtimes and all
their new modules (`Languages`, `GraduationGate.JS`/`.Go`, the `parse_response` rewrite,
reload/quarantine changes). Re-run `/graphify .` so `graphify_query` reflects current code.
Cheap (free via Elixir AST per the graph notes); do anytime.
