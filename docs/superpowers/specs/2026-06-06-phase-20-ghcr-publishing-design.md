# Phase 20 — GHCR Image Publishing Design

## Goal

Publish a Docker image to GitHub Container Registry (GHCR) on every successful push to `master`. The image is tagged with the short Git SHA and also re-tagged as `latest`.

---

## Context

Phase 16 produced a multi-stage `Dockerfile` and `docker-compose.yml`. Phase 17 added a CI workflow at `.github/workflows/ci.yml` that runs tests and a prod compile check. Phase 20 extends that workflow with a Docker build and push step that only runs after tests pass.

---

## Design

### Trigger

Same triggers as the existing CI job: push and PR to `master`. Docker publish only fires on `push` (not PRs from forks, which can't write to GHCR without access to secrets).

### Job structure

Option A — single job (test → build → push in sequence). Simpler, fewer moving parts.

Option B — two jobs (`test` then `publish`, with `needs: test`). Cleaner separation; publish step never runs if tests fail.

**Chosen: Option B.** The separation makes the intent obvious — publish is a deployment concern, not a test concern.

### Registry

`ghcr.io/<owner>/shem` — GHCR is free for public repos, no Docker Hub account required, and GitHub Actions natively authenticates to it via `GITHUB_TOKEN`.

### Image tags

| Tag | Value |
|---|---|
| `ghcr.io/<owner>/shem:latest` | Always the most recent build from `master` |
| `ghcr.io/<owner>/shem:<sha>` | Short Git SHA (7 chars) — pinnable, immutable |

Using `docker/metadata-action` generates both tags automatically.

### Authentication

`GITHUB_TOKEN` is automatically available in GitHub Actions. The `publish` job needs `packages: write` permission.

### Caching

Docker layer cache via `cache-from: type=gha` and `cache-to: type=gha,mode=max` (GitHub Actions cache backend). Keeps build times fast on incremental changes.

---

## Workflow Changes

Additions to `.github/workflows/ci.yml`:

```yaml
permissions:
  contents: read
  packages: write

jobs:
  ci:
    # ... existing job, unchanged ...

  publish:
    name: Build & push Docker image
    runs-on: ubuntu-latest
    needs: ci
    if: github.event_name == 'push'

    steps:
      - uses: actions/checkout@v4

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

**Top-level `permissions:` block** is added to the workflow file (not just the job) so the `GITHUB_TOKEN` scopes are locked down explicitly.

---

## File Map

| File | Action |
|---|---|
| `.github/workflows/ci.yml` | Modify — add `permissions:` block, add `publish` job |

---

## Testing Strategy

- No unit tests (purely infrastructure)
- Verify by: pushing to `master` → observe "Build & push Docker image" job succeeds → confirm image visible at `ghcr.io/<owner>/shem`
- Verify `latest` and SHA tags both appear in the GHCR package page
- Verify `publish` job does NOT run on a PR (only on push)
- Verify `publish` job does NOT run if `ci` job fails (tested by temporarily breaking a test)

---

## What's Not Included

- Multi-platform builds (`linux/arm64`) — add when needed
- Semantic version tags (`v1.2.3`) — add when releases are formalized
- Vulnerability scanning (Trivy, Snyk) — future phase
- Promotion from staging to prod tag — future phase
