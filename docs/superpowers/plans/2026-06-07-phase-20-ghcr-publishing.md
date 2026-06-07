# Phase 20 — GHCR Image Publishing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a Docker image to GHCR on every successful push to `master`, tagged with the short Git SHA and `latest`.

**Architecture:** Add a `publish` job to the existing `.github/workflows/ci.yml` that runs after the `ci` job passes, using `docker/metadata-action`, `docker/setup-buildx-action`, and `docker/build-push-action`. Add a top-level `permissions:` block to allow writing to the GHCR package registry. The `publish` job is gated to `push` events only so fork PRs never attempt to push.

**Tech Stack:** GitHub Actions, `docker/login-action@v3`, `docker/metadata-action@v5`, `docker/setup-buildx-action@v3`, `docker/build-push-action@v6`, GHCR (`ghcr.io`).

---

## File Map

| File | Action |
|---|---|
| `.github/workflows/ci.yml` | Modify — add `permissions:` block + `publish` job |

---

## Task 1: Add GHCR publish job to CI workflow

**Files:**
- Modify: `.github/workflows/ci.yml`

This is the only task. The complete final file content is shown in Step 2 so there is no ambiguity about indentation or structure.

- [ ] **Step 1: Verify the current file**

```bash
cat /home/philip/Downloads/_project/shem/.github/workflows/ci.yml
```

Expected: the file contains one job named `ci` with no `permissions:` block at the top level.

- [ ] **Step 2: Replace `.github/workflows/ci.yml` with the new content**

The complete new file:

```yaml
name: CI

on:
  push:
    branches: [master]
  pull_request:
    branches: [master]

permissions:
  contents: read
  packages: write

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

  publish:
    name: Build & push Docker image
    runs-on: ubuntu-latest
    needs: ci
    if: github.event_name == 'push'

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Docker metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository_owner }}/shem
          tags: |
            type=sha,prefix=,format=short
            type=raw,value=latest

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 3: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('/home/philip/Downloads/_project/shem/.github/workflows/ci.yml'))" && echo "YAML valid"
```

Expected: `YAML valid`

- [ ] **Step 4: Verify structure with grep**

```bash
grep -n "^jobs:\|^  ci:\|^  publish:\|^permissions:" /home/philip/Downloads/_project/shem/.github/workflows/ci.yml
```

Expected output (line numbers may differ):
```
8: permissions:
11: jobs:
12:   ci:
35:   publish:
```

- [ ] **Step 5: Verify existing tests still pass (workflow change is non-breaking)**

```bash
cd /home/philip/Downloads/_project/shem && mix test 2>&1 | tail -5
```

Expected: 566 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "feat: CI — add GHCR publish job on push to master"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Covered |
|---|---|
| `permissions: packages: write` for GHCR write access | ✅ Step 2 |
| `publish` job `needs: ci` | ✅ Step 2 |
| `if: github.event_name == 'push'` (no PRs) | ✅ Step 2 |
| `docker/login-action@v3` with `ghcr.io` and `GITHUB_TOKEN` | ✅ Step 2 |
| `docker/metadata-action@v5` — `type=sha,format=short` + `type=raw,value=latest` | ✅ Step 2 |
| `docker/setup-buildx-action@v3` | ✅ Step 2 |
| `docker/build-push-action@v6` with GHA layer cache | ✅ Step 2 |
| Image name: `ghcr.io/<owner>/shem` | ✅ Step 2 — uses `github.repository_owner` |
| Existing `ci` job unchanged | ✅ Step 2 — only additions |

**No placeholders found.**

**Type consistency:** N/A — pure YAML, no types.
