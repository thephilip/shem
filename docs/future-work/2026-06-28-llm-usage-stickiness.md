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
