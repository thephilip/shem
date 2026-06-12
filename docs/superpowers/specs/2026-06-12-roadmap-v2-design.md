# Roadmap v2 — Vision Review & Adjusted Phases (2026-06-12)

A review of `agent-framework.md` (the manifest) against what was actually built through
Phase 34, and an adjusted phase plan. Supersedes the phase ordering in
`2026-06-08-roadmap-phases-28-36-design.md` (whose positioning section remains valid).

---

## Verdict

The vision holds up. The drift is not in *what* got built — 34 phases delivered most of the
manifest's pillars — but in three quieter failure modes:

1. **Bookkeeping drift.** Three documents claimed to be the roadmap (the manifest, the
   June-8 roadmap doc, and session memory) and they disagreed with each other and with git
   history. Phase 32 (Timeline Viewer) was fully implemented but never recorded; the June-8
   doc's phase numbers stopped matching reality at Phase 33 (its HITL handoff was displaced
   by CLI/config; its Python SDK had already shipped as Phase 18). Orphaned along the way:
   HITL approval, travelling-agent detection, hive_mind, context proxy, GitHub bot.

2. **Depth drift.** Several pillars were built as shells that satisfy a phase checklist but
   not the manifest's actual claim:
   - *Pause-and-steer* (§3B): the manifest promises Spacebar pauses agent execution for
     mid-flight steering. What exists is a TUI display flag — agents keep running.
   - *Formal Graduation Gate* (§2A): the manifest requires property-based proofs of
     invariants. The actual gate runs whatever example test the agent wrote about itself.
   - *Cryptographic audit trail* (§4): events have causal `parent_id` links but no hash
     chain. The compliance story is currently aspirational.
   - *Hard token budget* (§3C): BudgetCheck is a per-call gate, not a circuit breaker with
     snapshot + continuation plan (though `Agent.resume` provides half the story).
   - *Trust-weighted consensus* (§2G): trust scores exist and gate execution, but there is
     no consensus voting because hive_mind was deferred. Pillar G is half-built.

3. **Priority drift.** The user's real daily usage emerged organically as "Shem is an MCP
   tool server for Claude Code" — the one angle no competitor (including Hermes) has. The
   roadmap had Phase 36 (MCP agent tools) sequenced *after* the much larger TUI phase.

## What was right

- The build order followed the manifest's §6 discipline almost exactly — infrastructure,
  event log, sandbox, LLM, distribution, adversarial/trust last. That discipline is why
  876 tests pass and the pillars exist at all.
- Choosing "make the TUI real" over "cut the TUI" (Phase 35) is correct given Hermes leads
  with theirs — but it is competitive parity, not differentiation, so it should not go first.
- The EventLog-not-git rollback decision, the container-boundary-over-fence decision, and
  the Backend behaviour (Local/Container, K8s later) are all the right primitives.

---

## Adjusted phase plan

### Phase 36 — MCP Agent Tools *(do first — reordered ahead of 35)*

As specced in `2026-06-11-phase36-mcp-agent-tools-design.md`. Four handlers + router
entries; days, not weeks. Reasons to go first: it compounds the differentiator instead of
chasing parity; it makes Shem useful to its own author every day (dogfooding pressure
beats speculation for finding what matters); and it is small enough to bank before the
larger TUI effort.

### Phase 35 — TUI: Make It Real

As specced in `2026-06-11-phase35-tui-real-design.md`. Unchanged in content.

### Phase 37 — Honest Claims *(new)*

Stop adding surface area; make three manifest claims true. Each is small because the
infrastructure underneath already exists:

1. **Real pause-and-steer.** `Agent.Server` gains a paused state that suspends the ReAct
   loop between turns; Spacebar in the TUI pauses the *focused agent*, not just the status
   bar; a steering message can be injected before resume. Conversational mode's
   `send_message/2` and the `:waiting` status are most of the machinery already.
2. **Property-gated graduation.** GraduationGate requires at least one StreamData property
   alongside example tests, or the tool graduates into a lower trust band. Requires
   promoting `stream_data` from test-only to a runtime dep.
3. **Hash-chained EventLog.** Each event carries `hash = H(prev_hash || payload)`;
   `EventLog.verify_chain/1` validates a session. This converts the enterprise audit-trail
   claim from marketing to fact, cheaply.

### Phase 38 — The Launch Demo *(new)*

The manifest's §7 demo is the keystone of the whole vision and no phase ever pointed at
it. Build it as a reproducible artifact, not a one-off: a docker-compose multi-node
cluster, a script that kills a node mid-task, a timeline fork with divergent outcomes, a
red-team round that patches a flaw, and the property test that proves the patch. Plus the
Benchee benchmark suite (from the future-items list) and a README v2 that leads with the
demo. Every prior phase exists to make this sequence possible; this phase makes it real.

### Phase 39 — Human-in-the-Loop `request_approval`

Re-homed from the June-8 roadmap's Phase 33 (displaced by CLI/config and never built).
A built-in tool `request_approval(action, reason)`; TUI/Web UI notification; approve or
deny; configurable per-preset and per-tool. Completes the guardrails story alongside
Phase 34's kill + fence.

---

## Deferred (unchanged status, now in one place)

- **hive_mind (The Council)** — explicitly noted: this is the missing half of manifest
  pillar G (trust-*weighted consensus*), not optional garnish. Schedule when multi-agent
  decisions have a real use case; the trust substrate is ready.
- **Project-in-container workflow** — the container boundary replaces the shell fence for
  coding sessions; next executor-track phase.
- **Travelling-agent detection** — fold into the Shadow Agent (extend its scoring to task
  drift) rather than building a separate detector.
- **Context proxy (headroom)**, **GitHub bot**, **K8s executor**, **federation**,
  **marketplace** — all post-launch.

## Recommended manifest edits (pending sign-off)

- **Demote §5A migration adapters** (LangChain/CrewAI import). The space moved: MCP
  interop is the adoption wedge in 2026, and Shem already has it from both sides
  (server + client). Importing 2024-era chain definitions is effort spent on a shrinking
  audience.
- **Decline messaging integrations** (Telegram/Discord/Slack — Hermes's strongest
  remaining edge). Own the dev-tool/MCP angle instead of chasing platform parity; a
  messaging bridge is a community-contribution-shaped feature once the MCP surface is rich.
- **Reword §2A/§3C/§4 claims to future tense** until Phase 37 lands, or land Phase 37
  before the README v2 makes the claims publicly.
