# Phase 17 — CI Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GitHub Actions workflow that runs `mix test` and `MIX_ENV=prod mix compile` on every push and PR to `master`.

**Architecture:** Single workflow file at `.github/workflows/ci.yml`. One job (`ci`) on `ubuntu-latest`: setup BEAM, restore dep cache, `mix deps.get`, `mix deps.compile`, `mix test`, `MIX_ENV=prod mix compile`, save cache. No Docker build in CI scope.

**Tech Stack:** GitHub Actions, `erlef/setup-beam@v1` (Elixir 1.19.5 / OTP 29.3), `actions/cache@v4`, `actions/checkout@v4`.

---

## Context

- Project root: `/home/philip/Downloads/_project/shem`
- All commits go directly to `master` — no feature branches
- `mix.exs` aliases `deps.get` and `deps.compile` to copy `priv/waf` into ex_termbox before compilation. Ubuntu runners have Python 3 pre-installed, so the waf build works without any extra setup.
- `config/test.exs` already sets `start_tui: false`, `start_mcp: false`, `start_cluster: false` — the test suite runs headlessly without a TTY or real services.
- `MIX_ENV` defaults to `dev` when not set; all test commands must use `MIX_ENV=test` (which `mix test` sets automatically).

---

## Task 1: GitHub Actions CI Workflow

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Create the workflow directory**

```bash
mkdir -p /home/philip/Downloads/_project/shem/.github/workflows
```

- [ ] **Step 2: Create `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  push:
    branches: [master]
  pull_request:
    branches: [master]

jobs:
  ci:
    name: Test & compile check
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: "1.19.5"
          otp-version: "29.3"

      - name: Restore dependency cache
        uses: actions/cache@v4
        with:
          path: |
            deps/
            _build/test/
          key: ${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}
          restore-keys: |
            ${{ runner.os }}-mix-

      - name: Install dependencies
        run: mix deps.get

      - name: Compile dependencies
        run: mix deps.compile

      - name: Run tests
        run: mix test

      - name: Check prod compilation
        run: MIX_ENV=prod mix compile
```

- [ ] **Step 3: Verify the file is valid YAML**

```bash
cd /home/philip/Downloads/_project/shem
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo "YAML valid"
```

Expected: `YAML valid`

- [ ] **Step 4: Verify the test suite still passes locally**

```bash
mix test 2>&1 | tail -5
```

Expected: `554 passed` (or more), 0 failures.

- [ ] **Step 5: Verify prod compile passes locally**

```bash
MIX_ENV=prod mix compile 2>&1 | tail -5
```

Expected: no errors (warnings are fine).

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "feat: GitHub Actions CI — mix test + prod compile check on push"
```

---

## Self-Review Checklist (coordinator use only)

- [x] Trigger: push + PR to `master`
- [x] `erlef/setup-beam@v1` with Elixir 1.19.5 + OTP 29.3
- [x] Cache: `deps/` + `_build/test/` keyed on `mix.lock` hash
- [x] `mix deps.get` (triggers waf patch alias)
- [x] `mix deps.compile`
- [x] `mix test`
- [x] `MIX_ENV=prod mix compile`
- [x] No Docker build (out of scope)
- [x] Single job, sequential steps
