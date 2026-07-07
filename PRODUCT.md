# Product

## Register

product

## Users

The developer / AI engineer who builds and operates Shem — a BEAM-native framework for
self-evolving, distributed agents. Primary user today is the project author, dogfooding;
the target market is users of Hermes and OpenClaw who need what those frameworks can't
offer: BEAM-native preemptive concurrency, fault recovery, and distributed agent meshes —
plus the combination those don't ship together, time-travel debugging *and* offline-verifiable
receipts on a local-first runtime.

Context of use: local, at `127.0.0.1:4000`, while a real agent run is happening or being
dissected after the fact — watching agents work across nodes, scrubbing a session's event
log, forking a timeline to test "what if the model had answered differently," and proving
the record wasn't tampered with. Often mid-incident, always on real data. Single user, one
machine; no multi-tenant, no auth surface, no internationalization yet.

## Product Purpose

The WebUI is the surface that turns Shem's lead differentiator — **time-travel debugging** —
from a README bullet into the thing that *sells* Shem. Rewind / fork / replay / verify is
invisible in a CLI or TUI; in a browser it is a demonstration: scrub the timeline, pick an
LLM turn, fork, watch the original and the fork diverge side-by-side, with a tamper-evident
hash-chain badge proving integrity. That is the "oh, I get it" moment — live divergence *and*
a verifiable log in one view, running locally with no external service behind it.

Success is *useful AND used*: the debugger is a magnet that makes someone keep Shem open.
The backend rails already exist (`/api/sessions/:id/{events,fork,verify}`, `/stream`,
`/metrics`, `/api/cluster`) — the product work is the visualization layer on top of them.

## Brand Personality

**Scientific instrument.** An oscilloscope or logic analyzer, not a SaaS dashboard. The
interface is precise, forensic, and engineered — dense where the work demands density,
measured everywhere else. Monospace numerics, hairline rules, exact alignment. Voice:
unshowy, confident, exact; it states facts about a running system and trusts the operator
to read them. Color is a coding system (event semantics, trust bands, verify state), never
decoration — when something is colored it *means* something.

Three words: **precise · forensic · engineered.**

## Anti-references

- **Generic SaaS dashboard** — card-grid + hero-metric + cool-gray everything. The default
  AI-product look. The timeline is a spine, not a grid of identical cards.
- **Cream / warm-neutral "editorial AI"** — sand/paper/parchment backgrounds with muted
  gray body text. The saturated 2026 AI default; reads as decoration, not instrument.
- **Contrived / demo-ware** — anything that looks staged or fake. The project deliberately
  cut its scripted `mix demo` for feeling contrived; the WebUI must read as a real
  instrument on real data, never a mock with stubbed numbers.
- **Cluttered / over-chromed** — glassmorphism, gradients-on-everything, neon overload.
  Style that obscures the data is the opposite of an instrument.

## Design Principles

1. **Instrument, not dashboard.** Every element earns its place by helping the operator
   read the system. No decoration that doesn't encode information.
2. **Real data or nothing.** Show the actual event log, the actual hash, the actual
   divergence between two runs. Never a staged number. Credibility is the whole product.
3. **Make the invisible visible.** The differentiator — rewind, fork, replay, verify — must
   be legible at a glance. The timeline is the spine; everything hangs off it.
4. **Density with hierarchy.** Forensic tools are information-dense; the discipline is
   ruthless visual hierarchy so density never becomes clutter.
5. **Trust is shown, not claimed.** Integrity (hash-chain verify) and agent trust bands are
   always visible state, never buried — they are the credibility of the time-travel story.

## Accessibility & Inclusion

- **WCAG 2.1 AA.** Body text ≥ 4.5:1, large text ≥ 3:1, against actual backgrounds
  (including tinted surfaces and placeholder text).
- **Colorblind-safe encoding.** The timeline codes event types and trust bands by color;
  color must never be the *only* channel — pair every semantic color with a shape, label,
  or position so the encoding survives deuteranopia/protanopia.
- **Reduced motion is mandatory.** Scrub, fork-diverge, and replay are motion-heavy; every
  animation needs a `prefers-reduced-motion: reduce` alternative (crossfade or instant).
- **Keyboard-operable timeline.** Scrubbing and turn selection must work from the keyboard
  (arrow keys to move along the timeline), not pointer-only.
