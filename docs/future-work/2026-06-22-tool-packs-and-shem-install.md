# Future Work: Shareable Tool Packs & `shem install`

_Status: deferred, but flagged by the user as a top differentiating idea (2026-06-22).
Documented so the vision + the "primitives already exist" insight survive._

## The idea
Graduated tools shouldn't be trapped in one machine's lab dir. They should be
**shareable, backable-up, version-controlled, and installable** — tools live in
git repos, and `shem install <repo>` pulls them into the local tool library.
A "tool pack" is a curated set tuned for a kind of work (security, data, web,
Elixir-dev, …), paired with a preset.

## Why this differentiates
No other agent framework ships this shape. Three things compound:
1. **Tools come with proof.** Shem's graduation gate runs each tool's tests
   (property tests rewarded). An installed pack carries its `test_source`; Shem
   **re-runs the gate locally** before trusting it — you install capability that
   re-verifies on your machine, not blind code.
2. **Git is the registry.** No marketplace server, no central infra, no account.
   Repos give distribution, versioning, forking, backup, and PR review for free.
3. **Self-evolution becomes social.** An agent graduates a tool once; it can be
   committed, shared, and pulled by other Shem users/projects. Capability
   compounds across people, not just sessions. Ties to
   `2026-06-22-token-saving-pitch` (memory) and the self-evolution differentiator.

## The primitives already exist (this is curation, not new infrastructure)
1. **Seeds** — the always-on base library (`Shem.SeedTools`, shipped 2026-06-22).
   Not removable by design (the floor).
2. **Graduated tools** — added at runtime, persisted as JSON manifests + source,
   and already **removable** (delete the manifest from the lab dir).
3. **`lab_dir` is configurable** (`:lab_dir` app env, default
   `~/.config/shem/lab`). Point it at a project → that project gets its own tool
   set. "Add tools for a project, remove when done" already works: stop using
   that project's lab dir. This is the latent per-project isolation.
4. **Presets** are already "tuned per work type" (`coder`, `researcher`,
   `security`, `*_toolsmith`). A tool pack is the tool-side analog; the natural
   pairing is a preset that declares which pack it wants.

## Lazy build path (in order — do NOT skip to the end)
1. **Now (free):** per-project `lab_dir` gives project-scoped, removable tools.
   Nothing to build.
2. **`shem install <git-url>` (~the wedge):** clone/pull the repo, copy its tool
   manifests + sources into the target lab dir, **run each through the graduation
   gate** (re-compile, re-test, re-score trust) before registering. Reject any
   that fail. `shem uninstall <pack>` removes the manifests. A pack is just a repo
   with a `tools/` dir of manifests + a `pack.json` (name, preset, version). No
   server, no central catalog.
3. **Preset ↔ pack binding:** a preset references a pack id; selecting the preset
   ensures its pack is installed.
4. **Only if real traction:** a browsable central catalog, ratings, dependency
   resolution, semver constraints. This is the roadmap-v2 "marketplace
   (post-launch)" item — premature until many packs exist. Defer hard.

## Trust & security (do NOT simplify away)
Installing a pack = running third-party code. This is a trust boundary:
- Installed tools MUST pass the local graduation gate (re-run tests) before they
  can be invoked — never trust the source repo's claim that they pass.
- Trust scoring + the gate's progressive hardening apply to installed tools the
  same as agent-authored ones; `:low` trust stays gated from execution.
- `:port`/polyglot tools should run in the container executor
  (`2026-06-22-container-polyglot.md`) — extra isolation for code you didn't write.
- A pack manifest should be signed or at least content-hashed so tampering in
  transit is detectable (the EventLog already does sha256 chaining — reuse the
  primitive, don't invent one).

## Trigger to build
Step 2 (`shem install` from a git repo) becomes worth building when there is a
second genuinely distinct, curated pack worth sharing — e.g. the user has built a
security pack and a data pack they want to reuse across projects. Until then, the
configurable `lab_dir` covers project-scoped tools.
