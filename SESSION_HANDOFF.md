# Session Handoff — 2026-06-21

All work committed and pushed (`master` == `origin/master`, head `439b3a2`). 1063 tests passing
(`mix test --exclude distributed`). North Star + auto-memory already updated for next session.

## Done this session
1. **Ponytail audit cleanup** — deduped `BudgetCheck`/`EventLogger` call/stream, deleted two
   boilerplate supervisors (inlined as `{DynamicSupervisor, ...}`), removed dead identity case,
   deleted root scratch files, replaced `ConfigFile.format/1`'s hardcoded YAML template with a
   generic recursive serializer (was silently dropping unknown keys).
2. **Phase 43b — `python_toolsmith` preset** — COMPLETE + VERIFIED. Preset added; `GraduationGate.Python`
   pip-installs hypothesis; `:python_integration` tests fixed to actually use the container (were
   silently on Local) and excluded by default. Proven live against qwen: agent wrote a Python tool,
   hit a test failure, fixed it, graduated; tool runs via PortPool.
3. **Progressive hardening** — COMPLETE. `GraduationGate.Hardening.check/2` = single `:shadow`
   LLM-turn trust review at graduation, refining the trust seed + logging `:hardening_check`. Full
   red-team loop is now opt-in (`Shem.Adversarial.start_hardening/1`); demo calls it explicitly.

## Known limitations / watch-outs
- **Hardening + local qwen**: qwen returns prose, not JSON, so the review degrades to safe `:skip`
  (flat 0.5 seed). Works for cloud / better-tuned models. Not a bug — the fallback is by design.
- **LLM authoring half of 43b** is proven; the env: LM Studio on `:1234` serves `qwen` (dev route
  `default: {:openai, "qwen"}`), NOT Ollama `:11434`.
- **Test gotcha**: never mutate the global `progressive_hardening` config in tests — `turn_test` is
  async and graduates tools, so the toggle races and steals stub LLM responses. Pass the enabled
  flag explicitly to `check/2` (already done).
- Dev boots the TUI (Ratatouille) which dies under piped `mix run` — use `mix run --no-start` +
  `Application.put_env(:shem, :start_tui, false)` + `ensure_all_started(:shem)` for scripts.

## Next candidates (North Star "Closed Decisions", none started)
- **Shem.Telemetry** (medium) — `:telemetry` events (agent turn p50/p99, EventLog append, PortPool
  round-trip, LLM latency/transport) + live TUI rolling stats.
- **Maturity labeling** (tiny, docs only) — README split: stable distribution layer (38–41) vs
  experimental self-evolution layer (42–43+).
- **EventLog GC + migration** (medium) — append-only logs grow unbounded; Mnesia schema evolution
  has no strategy. Gates any production-readiness claim.
- **Standalone binary** (large) — Burrito/Bakeware packaging of `mix demo`.
