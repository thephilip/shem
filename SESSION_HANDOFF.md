# Session Handoff — 2026-06-22

`master` pushed to origin (head after this commit). Full suite green: **1072 passed**
(`mix test --exclude distributed --exclude python_integration`).

## Shipped this session
- **Demo fix** (`b89ec04`) — peers now start `Shem.Trust.Store` with a per-node `/tmp` DETS path;
  the launch demo had been silently failing Phase 1. All 4 phases pass now.
- **Boot-crash fix** (`c16c6aa`) — one broken graduated tool on disk crashed app boot
  (`Lab.Registry.build_tool_from_manifest` hard-matched `extract_module`). Now skips + logs.
  Found while bringing up the MCP server headless.
- **`edit_file` builtin** (`27c7545`) — surgical `old_string→new_string` replace; whole-file
  rewrite was the main ergonomic gap vs Claude Code. Goes through the fence guardrail.
- **Trust bands in prompt** (`076023f`) — manifest already computed trust; now surfaced so the
  agent prefers higher-trust tools (the hard gate already blocked `:low`).
- **`ponytail` preset** (`00110ef`) — lazy/YAGNI agent mode (distilled from the MIT Ponytail skill,
  attributed in source). `/preset ponytail`.
- **`mix shem.serve`** (`8ad8001`) — headless MCP/REST server (TUI + cluster off).
- **dev LLM route** stays local qwen (keyless). Flip to `{:anthropic, ...}` needs `ANTHROPIC_API_KEY`.
- **graphify graph** (`ca0a012`) — refreshed + now tracked; 1206 nodes. Query it to navigate
  instead of full-parsing. Refreshes free via Elixir AST (`/graphify . --update`).
- Commit messages no longer carry the Co-Authored-By trailer (user preference).

## Using Shem as a tool server in Claude Code (keyless, no local LLM)
MCP server `shem` is registered in Claude Code local config and health-checks **✔ Connected**.
Tools load at session **startup**, so a NEW Claude session is required to call `mcp__shem__*`.

```bash
mix shem.serve            # leave running (MCP SSE at http://127.0.0.1:4000/mcp/sse)
# in a fresh terminal:
claude                    # new session → mcp__shem__execute_code, __invoke_tool, __graduate_tool, ...
```
- Verified live: `execute_code` ran an Elixir module in Shem's sandbox → `2870` over MCP/SSE.
- `spawn_agent` needs an LLM (LM Studio/qwen on `:1234`, currently DOWN). The keyless tools
  (`execute_code`, `invoke_tool`, `graduate_tool`, `list_tools`) do not.

## Next / open
- **Client-transport inversion** (DEFERRED, spec in auto-memory `project-client-transport-inversion`):
  let `spawn_agent` run Claude-Code-driven agents with no key/no local LLM. Claude Code lacks MCP
  `sampling`, so hand-roll it: `ClientTransport` (parks turn) + `provide_turn` MCP tool +
  suspend/resume in `Agent.Server`. Build only when Shem-orchestration-around-Claude is genuinely
  wanted; plain tool-calling already works keyless. This is the wedge to make Shem needed by
  Claude Code users the way local-LLM users need it.
- Prior ponytail audit cleanup items (1–9) remain valid — see commit `67286bb`'s handoff in git history.

## Watch-outs
- TUI (Ratatouille) dies under piped `mix run`; `mix shem.serve` already disables it.
- Never mutate global `progressive_hardening` config in async tests (steals stub LLM responses).
- `spawn_agent` is a blocking `GenServer.call` — mind timeouts (auto-memory `project-spawn-agent-timeout`).
