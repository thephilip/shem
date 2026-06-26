# Strategic Direction: WebUI as the Visual Debugger + "Reverse Tools" (2026-06-25)

Captured from a design conversation. Not a spec yet — the *direction* to brainstorm
into specs when picked up. Pairs with `2026-06-25-runtime-followups.md` (the P1–P4
backlog) and the North Star.

## The thesis

**The WebUI (`127.0.0.1:4000`) is where Shem's lead differentiator — time-travel
debugging — stops being a README bullet and becomes the thing that *sells* Shem.**
Rewind/fork/replay is invisible in a CLI/TUI. In a browser it's a demo: scrub the
timeline, click turn 6, fork, watch two runs diverge side-by-side, with a tamper-proof
hash badge. That's the screenshot and the "oh, I get it" moment no Python framework
can show. Lead the WebUI with it; everything else hangs off it.

**Key reframe (grounded in code):** the backend primitives already exist — the WebUI is
plain `Plug.Router`, and the rails are built:
- `GET /timeline`, `GET /api/sessions/:id/events`, `POST /api/sessions/:id/fork`,
  `GET /api/sessions/:id/verify` (hash-chain)
- `GET /api/agents/:id/stream` (live SSE), `/shadow`, `/result`, `POST /:id/message`
- `GET /metrics` (Prometheus), `GET /api/cluster` (node mesh), `/api/packs`, `/api/presets`

So "buggy / needs functionality" is the **front-end**, not missing backend. The work is a
visualization layer on rails that already run — much cheaper than it feels.

## Triage of the WebUI vision (ponytail lens)

- **P1 — Visual time-travel debugger.** Timeline scrub + fork + side-by-side replay +
  verify badge. The spine. Primitives exist; this is front-end.
- **P1-adjacent — Live monitoring.** Running agents across the node mesh, trust bands,
  per-node health. Partly built (`/stream`, `/metrics`, `/cluster`). Free win: `:os_mon`
  (already loaded — `cpu_sup`/`memsup`/`disksup`) feeds a per-BEAM-node health panel.
- **Good — Tool inspection.** Graduated tools: trust band, source, test results, watch a
  graduation happen live. Ties to the self-evolution differentiator. Read-only first.
- **Defer — Tool *building* in the UI.** The agent already authors+graduates tools; a
  human-in-browser builder reimplements the toolsmith with more surface. YAGNI until a
  concrete human need it serves better than asking the agent.
- **Don't build — a generic human-facing tool-runner.** The genuinely human-useful tools
  are the *introspection* ones (query your EventLog / tool-graph) — which ARE the
  debugger. A generic runner would just be a worse version of tools people already have.
- **Keep distinct — the two brain modes.** Shem-as-app (its own LLM, the WebUI chat) vs
  Shem-as-tool-server (MCP, external brain). Don't route the WebUI's own chat through MCP
  — that's a circle.

When picked up: this is a "clearer shown than told" candidate → run the brainstorm with
the visual companion (mockups in the loop).

## "Reverse tools" — the human-as-co-driver idea, and why it rides client-brain

The idea: a human at the WebUI injects an instruction that reaches the model (e.g. Claude)
and makes it act. The user independently reinvented **MCP sampling** (server asks the
client's LLM to do something — the inverse of a normal tool call).

**Verified facts (2026-06-25):**
- **MCP sampling is being deprecated** — 2026-07-28 spec (SEP-2577); remains ≥12 months but
  new implementations should NOT adopt it; migrate to direct LLM-provider integration.
- **Client support is thin:** Claude Code ✗ (FR anthropics/claude-code#1785),
  Claude Desktop ✗, OpenCode ✗ (FR anomalyco/opencode#11948). Amazon Bedrock AgentCore
  Runtime ✓ (the one runtime doing server-initiated today).
- **Sampling's successor is Multi Round-Trip Requests (SEP-2322)** — server returns an
  `InputRequiredResult` (`inputRequests` + opaque `requestState`); client gathers the
  answer and re-issues the original call with `inputResponses`.

**The punchline:** SEP-2322 is essentially Shem's shipped **client-brain loop**:

| MCP round-trip (SEP-2322, the future) | Shem client-brain (shipped) |
|---|---|
| server returns "input required" + state | agent parks `:awaiting_turn`, returns `prompt` + `turn_token` |
| client gathers the answer | the brain (Claude) reads the prompt, acts |
| client re-issues with `inputResponses` | `provide_turn(agent_id, turn_token, content)` |

So Shem already built the pattern the MCP spec is converging on. **Direction: build
"reverse tools" on the client-brain / round-trip PULL — never on deprecated sampling.**
The WebUI "co-driver" = a human injecting content into an agent's pending `prompt`, which
the looping brain picks up via `agent_status` and acts on via `provide_turn`. Works with
EVERY client today; forward-compatible with SEP-2322.

**Hard limit:** pull only works while the brain is actively looping on that agent. You
cannot wake an idle Claude — true server-push needs sampling, which isn't there and is
being removed. Don't design around push.

## Why this matters for positioning

"Useful AND used" is the bottleneck. A visual time-travel debugger is a *used* magnet — the
tangible demo. And the round-trip alignment is a real story: *"Shem already implements the
pattern MCP is standardizing on."* These are the market angles to lead with.
