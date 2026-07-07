# Project Blueprint: Shem - the word written on a golem's forehead to animate it (and erased to kill it).

## 1. System Vision & Philosophy
This project is an open-source, local-first, polyglot agent orchestration framework built on the Elixir/Erlang VM (BEAM). It is designed to act as an autonomous system that "wakes up smart" and grows as you use it.

The moat is the BEAM. Python-based frameworks (LangChain, CrewAI, AutoGen) are
architecturally constrained where the BEAM is native: true preemptive concurrency,
transparent fault recovery, and distributed multi-machine agent meshes. Time-travel
debugging and tamper-evident logs are *not* exclusive — LangGraph ships checkpoint
fork/replay; OpenFang and Dapr ship hash-chained receipts. Shem's edge is the
**combination on a fault-tolerant, local-first runtime**: deterministic replay
*from the log* + offline-verifiable attestation + agents that survive a node dying +
gated self-evolution — in one OSS framework, with no cloud, TEE, or external services.

### Core Distinctions
* **Correct Concurrency:** Uses the BEAM's native actor model (`GenServer`) to host autonomous agents as isolated processes. No asyncio, no GIL, no "one agent blocks everything."
* **Fault-Tolerant Self-Learning:** Agents safely write, compile, test, and run code (Elixir, Python, JS, etc.) inside sandboxed execution environments. If code crashes or enters an infinite loop, a Supervision Tree catches it and feeds the stack trace back to the agent's self-correction loop without disrupting the host application.
* **Functional & Humanized Generation:** Rejects sterile AI boilerplate. Code written or refactored by the system enforces functional programming principles (immutability, data pipelines). *(◐ partial — FP-style generation via presets works; named "personality profiles" like "The FP Artisan" are ○ planned, not implemented.)*
* **Creative Adaptability:** The architecture must remain flexible enough to absorb new ideas quickly. Premature rigidity is a failure mode. Surprising, unconventional approaches are welcome and should be preserved.

---

> **Status legend.** This is a design blueprint — it mixes what's built with what's
> intended. Tags: **✅ shipped** (in `lib/`, tested) · **◐ partial** (core shipped,
> scope narrower than described) · **○ planned** (design only, not yet in code).
> When in doubt, `git grep` beats this doc.

## 2. Architectural Pillars

### A. The Local "Lab" Sandbox (Privacy & Isolation) *(✅ shipped)*
* **The Messy Stage:** All autonomous code generation, dependency installation (`mix`, `pip`, `npm`), and testing loops happen inside a hidden local configuration directory (e.g., `~/.config/shem/lab/`).
* **Hidden Git Versioning:** The Lab maintains an isolated local `.git` repository managed entirely by the framework. Every self-correction attempt and structural test run is committed here as an atomic, local change.
* **The Production Registry:** Once a self-learned tool passes all test suites, it is "graduated" into a clean local tool library. Tools are only exported to the user's active workspace repo via explicit user command (squash-committed as a single, flawless rewrite).
* **Formal Graduation Gate:** Self-written code is property-gated: tools that prove invariants with StreamData properties graduate clean; tools with only example tests graduate at reduced trust (`:medium`) and stay visibly penalized until adversarial hardening earns it back. *(Live since Phase 37.)*

### B. Polyglot Processing (BEAM Ports) *(✅ shipped — Elixir, Python, JS/Deno, Go)*
* Non-Elixir tasks (Python data analytics, Node web-scraping, etc.) are managed via native Erlang Ports or wrapper utilities.
* Data streams between the BEAM and external runtimes over high-throughput standard input/output (stdio).
* OS-level runtime crashes are caught as process exit codes, ensuring total application isolation.

### C. The Model Context Protocol (MCP) Adapter *(✅ shipped — MCP server + client)*
* Implements an open MCP client layer native to the BEAM.
* Allows agents to dynamically spin up, monitor, and consume local or remote JSON-RPC MCP servers (e.g., database bridges, repository tools, local system access) as isolated sub-processes.

### D. Distributed Agent Mesh (BEAM Distribution) *(✅ shipped, Phases 38–41, v0.4.0)*
* BEAM nodes connect across machines natively — no Kubernetes, no Redis, no message broker required.
* Agents can migrate between nodes based on load, hardware availability (GPU vs CPU), or data locality. *(Phase 40: `placement: {:model, m}` hints)*
* Node failure triggers automatic supervisor-tree redistribution of workload with zero data loss. *(Phase 40: crash recovery via Mnesia checkpoints)*
* Graceful evacuation on SIGTERM: agents checkpoint-flush before exit, resume on survivors with no turn regression. *(Phase 40)*
* Full TUI parity for remote agents: tokens stream cross-node via `:pg` groups; node badge shows agent location. *(Phase 41)*
* The target demo: 50 agents across 5 machines, one node dies mid-task, the work completes without interruption. *(enabled by Phase 41)*
* Spec: `docs/superpowers/specs/2026-06-13-distributed-mesh-design.md`

### E. Event-Sourced Timeline Engine ("Agent Git") *(✅ shipped — incl. `replay --check`, `attest`, GC)*
* Every LLM call, tool invocation, and state mutation is appended to an immutable event log.
* The system can **rewind** to any point in an agent's reasoning history.
* **Fork** a timeline: branch off from any moment and let it play out with different context or instructions.
* **Diff two runs** that started identically but diverged.
* **Deterministic replay** for debugging, auditing, and regression testing.
* This makes agents debuggable like real software — not log-spelunking.

### F. Adversarial Self-Improvement Loop *(◐ partial)*
* Dedicated "red team" agents whose sole job is to find failure modes, exploit edge cases, and break other agents. *(✅ opt-in via `Shem.Adversarial.start_hardening/1`; single-turn trust review runs automatically at graduation.)*
* When a vulnerability is found, the target agent patches itself and the red team runs again. *(○ planned — the automatic patch-and-rerun loop is not wired; hardening currently adjusts trust scores, it does not auto-patch.)*
* Agents get more robust over time under continuous adversarial pressure — not just more capable.

### G. Trust-Weighted Agent Consensus *(○ planned — no implementation in `lib/`)*
* In multi-agent decisions, each agent's vote is weighted by its dynamically updated trust score — historical accuracy on similar task classes, maintained in Mnesia.
* Agents that are reliably correct in a domain earn greater decision weight there.
* Proof-of-competence governance, not just majority voting.

---

## 3. User Experience & Interface Constraints

### A. High-Contrast Terminal UI (TUI) *(✅ shipped; a browser Web UI at `:4000` also ships and is the primary time-travel surface)*
* Built natively in Elixir using declarative TUI frameworks (e.g., Ratatouille or Owl) supporting 24-bit true-color ANSI.
* **Visual Aesthetic:** Strict requirements for high-contrast IDE syntax highlighting. Log errors flash neon red, successful pipelines highlight in emerald green, and agent "internal monologue" streams in dim, italicized colors.
* **Multi-Mode UI:** Toggled via keyboard hotkeys:
  1. *Dashboard/Ops Mode:* Bird's-eye view tracking host metrics (CPU, Memory, GPU), live token-spend odometers, and active agent execution bubbles.
  2. *Interactive/Dev Mode:* Pane layout showing raw code execution, live `git diff` outputs, and a prompt field.
  3. *Timeline Mode:* Visual replay of the event log — scrub through agent reasoning history, branch, and fork from any point.

### B. Interaction Model: Command & Monologue
* **Slash Commands (`/`):** Explicit user control mechanism (e.g., `/style artisan`, `/rewind [steps]`, `/fork [step]`, `/mcp status`, `/skills list`, `/trust scores`).
* **Pause-and-Steer:** Pressing `Spacebar` pauses the focused agent at its next turn boundary; typed input is injected into its context as steering, and `Spacebar` resumes it with the steering applied. The full interaction is recorded in the event log (`:agent_paused → :agent_steered → :agent_unpaused`). *(Live since Phase 37.)*
* **Travelling-agent / task-drift detection:** Extend Shadow Agent scoring to detect when an agent has drifted from its original task — do not build a separate detector; fold into `Shem.Shadow.Agent` as an additional scoring dimension. *(Deferred — Shadow Agent substrate is ready.)*

### C. Hard Token Budget Enforcement *(○ planned — no implementation in `lib/`)*
* Circuit breakers enforced at the VM supervisor level — not soft warnings.
* When an agent approaches its budget, it autonomously snapshots state, writes a continuation plan to disk, and halts gracefully.
* No runaway API bills. Resume is a first-class operation.

---

## 4. State & Memory Persistence ("Wake Up Smart")
* **Code as Data:** Graduated tools are written to disk as standard source files. Upon booting up, the application scans the library directory and hot-loads them natively into the VM.
* **Native Storage:** Episodic memories, user preferences, style vectors, and execution token logs are persisted using zero-overhead Erlang disk storage (DETS/Mnesia). No external Dockerized database configurations are required to run the tool.
* **Cryptographic Audit Trail:** Every event is a hash-chained record (per-session sha256; each hash commits to the event's identity, payload, timestamp, and causal link). Any retroactive edit breaks every subsequent link. Verifiable via `EventLog.verify_chain/1` or `GET /api/sessions/:id/verify`. *(Live since Phase 37.)*
* **Style Vectors as Shareable Artifacts:** *(○ planned)* Personality profiles ("FP Artisan", etc.) are serializable, versioned configs publishable to a community registry. A culture of shared agent personalities, like dotfiles but for cognition. *(Presets exist today; serializable style vectors and a registry do not.)*

---

## 5. Ecosystem & Adoption Strategy

*(Entire section ○ planned — none of this is implemented. Migration adapters are ROADMAP Phase 7, the "Hermes off-ramp".)*

### A. Migration Adapters (the "jump ship" story)
* First-class import adapters for LangChain chains, CrewAI crews, and AutoGen agents.
* Imported agents run inside BEAM-supervised Python Ports and appear as native Shem agents in the TUI.
* Switching cost: near zero. What users gain: fault tolerance, timeline replay, distributed mesh, hard budget caps.

### B. Capability Marketplace
* Graduated tools carry formal performance benchmarks.
* If two tools solve the same problem, the better-performing one is routed to automatically.
* A community registry of signed, versioned graduated tools creates a network-effect flywheel: the framework improves in capability just by having more users.

---

## 6. Development Strategy (Atomic Steps)
When writing code for this project, the implementation must be highly modular and disciplined:
1. **Infrastructure First:** Establish the baseline application layout (`mix new`), process registry, and supervisor tree configuration.
2. **The TUI Core:** Implement the basic terminal window rendering and input handling before handling heavy AI loops.
3. **The Sandbox Framework:** Build the code compiler and evaluation task loops that safely trap errors and capture stack traces.
4. **Event Log Engine:** Implement the append-only event store and timeline replay/fork machinery before integrating LLMs.
5. **Integration Loops:** Bring in MCP, local LLM tooling (via Bumblebee/Ollama bindings), and multi-agent message routing sequentially.
6. **Distribution Layer:** Add BEAM node clustering and agent migration after single-node stability is proven.
7. **Adversarial Loop & Trust System:** Red team agents and consensus weighting come last, built on top of a stable multi-agent foundation.

---

## 7. The Demo That Ships the Story
A single demo sequence for launch/announcement:
1. A cluster of agents solving a real coding problem across multiple machines.
2. Kill one node mid-execution — the work continues without interruption.
3. Show the event log: scrub back to step 15, fork the timeline, inject different context.
4. Show both timelines diverge and produce different results.
5. Red team agent finds a flaw in the solution from timeline A; the agent patches itself.
6. Show the property-based tests that prove the patch is correct.

This sequence demonstrates concurrency, fault tolerance, time-travel debugging, adversarial improvement, and formal correctness in one narrative arc. Individual pieces exist elsewhere — LangGraph forks timelines, OpenFang/Dapr chain audit logs — but no other framework spans the whole arc on a fault-tolerant, local-first runtime.
