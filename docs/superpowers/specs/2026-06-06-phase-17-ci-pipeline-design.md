# Phase 17 — CI Pipeline Design

## Goal

Run `mix test` and `MIX_ENV=prod mix release` on every push and pull request to `master` via GitHub Actions.

---

## Context

Shem is an Elixir 1.19.5 / OTP 29 project on Garuda Linux (Arch) in development, deploying to Debian trixie via Docker. The test suite has 554 tests. `mix.exs` aliases `deps.get` and `deps.compile` to apply a waf patch (`priv/waf` → `deps/ex_termbox/c_src/termbox/waf`) — Python 3 must be available on the runner for ex_termbox to compile. Ubuntu runners have Python 3 pre-installed.

---

## Design

### File

Single workflow file: `.github/workflows/ci.yml`

### Trigger

```yaml
on:
  push:
    branches: [master]
  pull_request:
    branches: [master]
```

### Runner

`ubuntu-latest` — has Python 3, git, build-essential pre-installed.

### BEAM Setup

`erlef/setup-beam@v1` with:
- `elixir-version: 1.19.5`
- `otp-version: 29.3`

### Caching

Two cache entries keyed on `hashFiles('mix.lock')`:
- `deps/` — downloaded packages
- `_build/test/` — compiled test artifacts

Separate test/prod build dirs means the cache doesn't need to be invalidated when switching `MIX_ENV`.

### Steps (single job: `ci`)

1. `actions/checkout@v4`
2. `erlef/setup-beam@v1` (Elixir 1.19.5, OTP 29.3)
3. Restore cache (`deps/` + `_build/test/`)
4. `mix deps.get` (triggers waf patch alias)
5. `mix deps.compile`
6. `mix test`
7. `MIX_ENV=prod mix compile` (catches prod-only compilation failures without a full release build)
8. Save cache

### What's Not Included

- `MIX_ENV=prod mix release` — the `mix compile` check in step 7 catches prod regressions. A full release takes ~30s extra and adds little signal after the compile check passes.
- Docker build — slow (~5 min), requires Docker-in-Docker. Add in a future phase when container publishing is needed.
- Code coverage, dialyzer, credo — out of scope for Phase 17.

---

## File Map

| File | Action |
|---|---|
| `.github/workflows/ci.yml` | Create |

---

## Success Criteria

- Green badge on `master` after a passing push
- `mix test` failure causes the job to fail (non-zero exit)
- `MIX_ENV=prod mix compile` failure causes the job to fail
- Dep cache hits on repeat pushes (verified by "Cache restored" in Actions logs)
