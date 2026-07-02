# Making an LLM Actually Use Shem (the "used" half of useful-AND-used)

_Captured 2026-06-28. Strategy + concrete levers. The North Star's bottleneck is
"useful AND **used**"; we've invested heavily in *useful* (capabilities), barely
in *used* (getting an LLM to consistently reach for Shem). This is that gap._

## The question

When Shem runs as an MCP tool server for an external brain (Claude Code, etc.),
**what makes the model consistently choose Shem's tools** — `spawn_agent`,
`graduate_tool`, `invoke_tool`, time-travel — instead of just doing the task
inline? Right now: almost nothing deliberate.

## What exists today (all passive)

- Shem is a connected MCP server; its tools are *available*.
- Tool **descriptions** (`MCP.Router` `tools/list` → `builtin_tool_descriptors`)
  describe *what* each tool does. That is the only nudge toward use.

## The gaps (grounded in code)

- **No MCP `instructions` field.** `MCP.Router.dispatch_method("initialize", …)`
  (`lib/shem/mcp/router.ex:74`) returns only `protocolVersion`, `capabilities`,
  `serverInfo` — **no `instructions`**. The MCP `instructions` field is the
  standard mechanism for a server to give the *client model* system-prompt-level
  guidance ("I'm Shem; reach for me to spawn fault-tolerant parallel agents,
  persist tools you write so they survive, and fork/replay/verify a run"). Most
  clients surface it to the model. It is the single cheapest, highest-leverage
  lever and it is currently unset.
- **Descriptions say "what," not "when."** They don't frame *when to prefer Shem
  over doing it yourself* — which is what actually drives selection.
- **No in-band reinforcement.** Nothing reminds the model that a graduated tool
  *persists*, or that `spawn_agent` buys preemptive concurrency / survives node
  death. Each call starts cold.

## The uncomfortable truth

**Nothing guarantees an LLM uses a tool** — selection is probabilistic, and
prompt-nudging only shifts odds. The reliable driver of consistent use is not a
better description; it is **being needed** — Shem being the only/best way to do
something the model genuinely cannot do inline:

- persistent, self-written tools tuned to *this* user (self-graduation),
- agents that survive a killed node (distribution + Horde),
- deterministic fork/replay/verify of a run (time-travel).

Capability the model can't replicate in its own context window is stickier than
any instruction. So the strategy is two-pronged: **nudge** (cheap, do it) AND
**be needed** (the real moat).

## The structural half: the client-brain round-trip (and being ahead of the fold)

The cheapest levers above are *nudges* (shift the odds). The strongest mechanism
Shem already owns is **structural**: the shipped client-brain loop — agent parks
`:awaiting_turn`, returns `prompt` + `turn_token`, advances on `provide_turn`. That
is the round-trip pattern (MCP SEP-2322) the ecosystem is converging on **as
sampling is deprecated** (2026-07-28, SEP-2577; see `reference-mcp-sampling`). Shem
already implements the pattern MCP is standardizing on — the real "ahead of the
fold" position.

Why it matters for *used*: a parked agent **pulls** the brain — it *requires*
`provide_turn` to advance, so engagement is structural, not probabilistic. That is
stickier than any description.

**Honest limit:** the pull only works **while a brain is already looping on that
agent; you cannot wake an idle one** (true server→client push needs sampling, which
is dying). So the round-trip **deepens** engagement once an agent exists — it does
**not** solve cold start ("why would Claude spawn a Shem agent at all?"). Hence
nudge and pull are **complementary, not either/or**:
- **Nudge** (`instructions` field, "when to use" descriptions) → gets the brain to
  *start* a loop.
- **Round-trip pull** → keeps it engaged.

### Implication for the main page (`/`) — reopen the chat-routing decision

`/` (`index.html`) is today a Shem-as-app chat on the **model brain** (local LLM) —
dead without LM Studio. The 2026-06-25 direction note said "keep the chat as
Shem-as-app, own LLM; don't route it through MCP." **That decision deserves
reopening:** the fork-continue work proved a chat-shaped loop runs **keyless** via
the client brain (`provide_turn`). So the compelling `/` is not a local-LLM chatbox
but a **co-driver surface** — the human (or a connected Claude) supplies the agent's
turns through the round-trip. That `/` works with no local model AND showcases the
differentiator instead of being a generic chat. (The genuinely-needed differentiator
remains the debugger; a keyless co-driver `/` would at least stop the front door from
being a dead chat — see the open front-door question: should `/` even be the chat, or
the debugger / a live-agents view?)

**Update 2026-07-02:** the fork-lane human co-driver is being built first (REST rail:
`GET /api/agents/:id` gains prompt+turn_token when parked, `POST /api/agents/:id/turn`,
`GET /api/tools`; co-driver strip in the timeline fork lane). The front-door `/`
co-driver is DEFERRED, not dropped — when picked up it reuses that rail and strip
unchanged; the only new work is the surface (agent list on `/`) and answering the
open question above.

## Concrete levers, cheapest first

1. **Set the MCP `instructions` field** (`MCP.Router` initialize). Small change,
   real leverage. State what Shem is and the 3–4 moments to reach for it. The
   highest ROI item here.
2. **Rewrite tool descriptions as "when to use X instead of doing it yourself"**
   (e.g. `graduate_tool`: "when you've written code you'll need again — graduate
   it so it persists and is re-verified, instead of re-deriving it next time").
3. **Surface persistence/recovery in tool *results*** — e.g. `graduate_tool`
   returns "now permanently available as `<name>`; future sessions can call it,"
   so the model learns the payoff in-band.
4. **Lean into needed-not-nudged capabilities** so there's a reason to come back:
   the client-brain loop ([[project-client-transport-inversion]]), self-graduation,
   the token-saving navigation pitch ([[project-token-saving-pitch]]).

## Measurement

Don't guess: instrument tool-call frequency per session (Telemetry already exists)
and watch whether the `instructions` field + "when to use" descriptions move it.
"Used" is the metric, not "shipped."

## Related

North Star ("useful AND used" bottleneck), `project-mcp-server-usage`,
`project-token-saving-pitch`, `project-client-transport-inversion`.
