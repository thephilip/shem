# Phase 29: README + Install Script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Shem publicly presentable with a compelling README, a one-liner install script, and a CI pipeline that publishes prebuilt OTP release binaries to GitHub Releases on version tags.

**Architecture:** Four independent deliverables — a LICENSE file, an `install.sh` shell script at the repo root, a rewritten `README.md`, and a new `.github/workflows/release.yml` CI workflow. The install script extracts the full OTP release to `~/.local/lib/shem/` and creates a wrapper at `~/.local/bin/shem` that calls `start` so users just type `shem`. The CI release pipeline builds three platform binaries (Linux x86_64, macOS Intel, macOS ARM64) in parallel on push of a `v*` tag.

**Tech Stack:** Bash (install script), GitHub Actions (release CI), Markdown (README), MIT License.

---

## File map

| File | Action | Purpose |
|------|--------|---------|
| `LICENSE` | Create | MIT license |
| `install.sh` | Create | One-liner install script |
| `README.md` | Rewrite | Public-facing project README |
| `.github/workflows/release.yml` | Create | Tag-triggered release pipeline |

---

### Task 1: MIT License

**Files:**
- Create: `LICENSE`

- [ ] **Step 1: Create `LICENSE`**

```
MIT License

Copyright (c) 2026 Philip Smith

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Commit**

```bash
git add LICENSE
git commit -m "chore: add MIT license"
```

---

### Task 2: Install script

**Files:**
- Create: `install.sh`

The OTP release structure (confirmed from the existing build):
```
~/.local/lib/shem/
├── bin/shem          ← OTP shell script (requires the erts/ tree beside it)
├── erts-17.0.1/
├── lib/
└── releases/
```

The install script extracts the full release to `~/.local/lib/shem/`, then creates a thin wrapper at `~/.local/bin/shem` that calls `bin/shem start` so users just type `shem` to launch.

- [ ] **Step 1: Create `install.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO="thephilip/shem"
LIB_DIR="${HOME}/.local/lib/shem"
BIN_DIR="${HOME}/.local/bin"
WRAPPER="${BIN_DIR}/shem"

# --- platform detection ---
OS=$(uname -s)
ARCH=$(uname -m)

case "${OS}-${ARCH}" in
  Linux-x86_64)  TARGET="shem-linux-x86_64.tar.gz"  ;;
  Darwin-x86_64) TARGET="shem-macos-x86_64.tar.gz"  ;;
  Darwin-arm64)  TARGET="shem-macos-arm64.tar.gz"   ;;
  *)
    echo "Unsupported platform: ${OS}-${ARCH}"
    echo "Build from source: https://github.com/${REPO}"
    exit 1
    ;;
esac

# --- fetch latest release tag ---
LATEST=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' | head -1 | cut -d'"' -f4)

if [ -z "${LATEST}" ]; then
  echo "Could not determine latest release. Check https://github.com/${REPO}/releases"
  exit 1
fi

URL="https://github.com/${REPO}/releases/download/${LATEST}/${TARGET}"

echo "Installing shem ${LATEST} (${OS}-${ARCH})..."

# --- extract release ---
rm -rf "${LIB_DIR}"
mkdir -p "${LIB_DIR}"
curl -fsSL "${URL}" | tar -xz -C "${LIB_DIR}" --strip-components=1

# --- create wrapper ---
mkdir -p "${BIN_DIR}"
cat > "${WRAPPER}" <<'EOF'
#!/bin/sh
exec "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/../lib/shem/bin/shem" start "$@"
EOF
chmod +x "${WRAPPER}"

# --- smoke test ---
if ! "${LIB_DIR}/bin/shem" version >/dev/null 2>&1; then
  echo "Install failed — binary did not run."
  rm -f "${WRAPPER}"
  exit 1
fi

echo ""
echo "shem ${LATEST} installed."
echo ""
echo "You're ready. Run \`shem\` to start."
echo ""

if ! echo ":${PATH}:" | grep -q ":${BIN_DIR}:"; then
  echo "  Note: add ${BIN_DIR} to your PATH"
  echo "    echo 'export PATH=\"\${HOME}/.local/bin:\${PATH}\"' >> ~/.bashrc"
  echo "    (or ~/.zshrc / ~/.config/fish/config.fish)"
fi
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x install.sh
```

- [ ] **Step 3: Lint with shellcheck**

```bash
shellcheck install.sh
```

If shellcheck is not installed: `sudo apt install shellcheck` (Linux) or `brew install shellcheck` (macOS).

Expected: no errors or warnings. Fix any that appear before continuing.

- [ ] **Step 4: Test platform detection locally**

```bash
# Test unsupported platform path
OS=Windows ARCH=x86_64 bash install.sh 2>&1 | grep "Unsupported"
```

Expected output: `Unsupported platform: Windows-x86_64`

- [ ] **Step 5: Commit**

```bash
git add install.sh
git commit -m "feat: add install.sh — one-liner OTP release installer"
```

---

### Task 3: README

**Files:**
- Modify: `README.md` (full rewrite)

The current `README.md` is the default Mix placeholder. Replace it entirely.

Note: badges reference `thephilip/shem`. The CI badge URL format for GitHub Actions is:
`https://github.com/thephilip/shem/actions/workflows/ci.yml/badge.svg`

- [ ] **Step 1: Rewrite `README.md`**

```markdown
<p align="center">
  <img src="shem.png" alt="Shem" width="480">
</p>

<h1 align="center">shem</h1>

<p align="center">
  <strong>The first AI agent platform you can actually debug.</strong>
</p>

<p align="center">
  <a href="https://github.com/thephilip/shem/actions/workflows/ci.yml">
    <img src="https://github.com/thephilip/shem/actions/workflows/ci.yml/badge.svg" alt="CI">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License">
  </a>
</p>

---

Shem is a general-purpose AI agent platform that runs on your machine.
Ask it to review your code, research a topic, draft a document, or audit
a security posture — then watch exactly what it did and why, turn by turn,
with a replayable event log no Python-based framework can match.

Works with Claude, ChatGPT, Ollama, llama.cpp, and any OpenAI-compatible API.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/thephilip/shem/master/install.sh | bash
```

Supports Linux x86_64, macOS Intel, and macOS Apple Silicon. No Elixir or Erlang installation required — the runtime is bundled.

Or with Docker:

```bash
docker run -it --rm \
  -v "$PWD":/workspace \
  -e SHEM_LLM_URL=http://host.docker.internal:11434 \
  ghcr.io/thephilip/shem:latest
```

## Why Shem?

**Debuggable.** Every LLM call, tool use, and agent decision is logged, replayable, and forkable. When something goes wrong, you find out why — not just that it did.

**Real concurrency.** Built on the BEAM (Erlang VM). Agents run as supervised OTP processes. No GIL, no asyncio, no mystery crashes under load.

**Not just for coding.** Six built-in presets cover the main use cases. Switch mid-conversation. Create custom presets from a role description with one command.

## Quick start

After installing, run `shem` in any project directory:

```
$ shem
```

Shem detects your project type automatically and injects the working directory
into the agent's context. Type anything to start a conversation.

```
> what does this project do?
> /preset security
> review the auth module for vulnerabilities
> /help
```

## Presets

| Preset | Purpose |
|--------|---------|
| `general` | Conversational assistant. The default. |
| `coder` | Code reading, writing, refactoring, debugging. |
| `researcher` | Information synthesis, summarisation, structured notes. |
| `writer` | Drafting, editing, tone adjustment. |
| `security` | Vulnerability identification, threat modelling. Conservative tool access. |
| `explorer` | Codebase and filesystem exploration. Read-only. |

Switch mid-conversation: `/preset coder`

Create your own: `/hire <name> <role description>`

## Configuring an LLM

Set the LLM endpoint in `config/runtime.exs` or via environment variables:

```elixir
# config/runtime.exs
config :shem, :llm_url, System.get_env("SHEM_LLM_URL", "http://localhost:11434")
config :shem, :llm_model, System.get_env("SHEM_LLM_MODEL", "llama3:latest")
```

Shem works with any OpenAI-compatible API — Ollama, llama.cpp, OpenAI, Anthropic (via proxy), and others.

## Build from source

Requires Elixir 1.19+ and OTP 29+.

```bash
git clone https://github.com/thephilip/shem
cd shem
mix deps.get
mix run --no-halt         # development
# or
MIX_ENV=prod mix release
./_build/prod/rel/shem/bin/shem start
```

## Roadmap

See [`docs/superpowers/specs/2026-06-08-roadmap-phases-28-36-design.md`](docs/superpowers/specs/2026-06-08-roadmap-phases-28-36-design.md) for the full roadmap.

Upcoming: hive_mind multi-agent consensus, Timeline Viewer, Human-in-the-Loop approvals, Shadow Agent confidence scoring, and more.

## License

MIT — see [LICENSE](LICENSE).
```

- [ ] **Step 2: Verify it renders correctly**

Open the file in a Markdown previewer or push to GitHub and check the rendered view. Confirm:
- Image loads (shem.png is at repo root ✓)
- Badges are visible
- Code blocks are formatted correctly
- Table renders

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "feat: replace placeholder README with public-facing project page"
```

---

### Task 4: Release CI pipeline

**Files:**
- Create: `.github/workflows/release.yml`

This workflow triggers on `v*` tags, builds three platform binaries in parallel, then creates a GitHub Release with all three tarballs attached.

**Important:** The existing `mix.exs` uses a `patch_waf` hook in the `deps.compile` alias to fix a Python 3.11 incompatibility in `ex_termbox`. The release workflow must use the same `mix deps.compile` invocation (not `mix compile`) to trigger the patch.

**Tarball structure** (confirmed from `_build/prod/rel/shem/`):
When tarred as `tar -czf shem-linux-x86_64.tar.gz shem/` from inside `_build/prod/rel/`, the tarball contains `shem/` at the top level. The install script uses `--strip-components=1` to extract into `~/.local/lib/shem/`, producing:
```
~/.local/lib/shem/bin/shem
~/.local/lib/shem/erts-*/
~/.local/lib/shem/lib/
~/.local/lib/shem/releases/
```

- [ ] **Step 1: Create `.github/workflows/release.yml`**

```yaml
name: Release

on:
  push:
    tags: ["v*"]

permissions:
  contents: read

jobs:
  build-linux:
    name: Build Linux x86_64
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: erlef/setup-beam@v1
        with:
          elixir-version: "1.19.5"
          otp-version: "29.3"

      - name: Restore dependency cache
        uses: actions/cache@v4
        with:
          path: |
            deps/
            _build/prod/lib/
          key: ${{ runner.os }}-mix-prod-${{ hashFiles('mix.lock') }}

      - name: Install dependencies
        run: mix deps.get --only prod

      - name: Compile dependencies
        run: mix deps.compile

      - name: Build release
        run: MIX_ENV=prod mix release

      - name: Package
        run: |
          cd _build/prod/rel
          tar -czf shem-linux-x86_64.tar.gz shem/

      - uses: actions/upload-artifact@v4
        with:
          name: shem-linux-x86_64
          path: _build/prod/rel/shem-linux-x86_64.tar.gz

  build-macos-intel:
    name: Build macOS x86_64
    runs-on: macos-13
    steps:
      - uses: actions/checkout@v4

      - uses: erlef/setup-beam@v1
        with:
          elixir-version: "1.19.5"
          otp-version: "29.3"

      - name: Restore dependency cache
        uses: actions/cache@v4
        with:
          path: |
            deps/
            _build/prod/lib/
          key: ${{ runner.os }}-mix-prod-${{ hashFiles('mix.lock') }}

      - name: Install dependencies
        run: mix deps.get --only prod

      - name: Compile dependencies
        run: mix deps.compile

      - name: Build release
        run: MIX_ENV=prod mix release

      - name: Package
        run: |
          cd _build/prod/rel
          tar -czf shem-macos-x86_64.tar.gz shem/

      - uses: actions/upload-artifact@v4
        with:
          name: shem-macos-x86_64
          path: _build/prod/rel/shem-macos-x86_64.tar.gz

  build-macos-arm64:
    name: Build macOS ARM64
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - uses: erlef/setup-beam@v1
        with:
          elixir-version: "1.19.5"
          otp-version: "29.3"

      - name: Restore dependency cache
        uses: actions/cache@v4
        with:
          path: |
            deps/
            _build/prod/lib/
          key: ${{ runner.os }}-mix-prod-${{ hashFiles('mix.lock') }}

      - name: Install dependencies
        run: mix deps.get --only prod

      - name: Compile dependencies
        run: mix deps.compile

      - name: Build release
        run: MIX_ENV=prod mix release

      - name: Package
        run: |
          cd _build/prod/rel
          tar -czf shem-macos-arm64.tar.gz shem/

      - uses: actions/upload-artifact@v4
        with:
          name: shem-macos-arm64
          path: _build/prod/rel/shem-macos-arm64.tar.gz

  release:
    name: Create GitHub Release
    needs: [build-linux, build-macos-intel, build-macos-arm64]
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: shem-linux-x86_64

      - uses: actions/download-artifact@v4
        with:
          name: shem-macos-x86_64

      - uses: actions/download-artifact@v4
        with:
          name: shem-macos-arm64

      - name: Create release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          GH_REPO: ${{ github.repository }}
        run: |
          gh release create "${{ github.ref_name }}" \
            shem-linux-x86_64.tar.gz \
            shem-macos-x86_64.tar.gz \
            shem-macos-arm64.tar.gz \
            --title "Shem ${{ github.ref_name }}" \
            --generate-notes
```

- [ ] **Step 2: Validate the YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" && echo "YAML valid"
```

Expected: `YAML valid`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "feat: add release.yml — tag-triggered multi-platform OTP release pipeline"
```

---

### Task 5: Cut v0.1.0 and verify end-to-end

This task pushes everything to GitHub, triggers the release pipeline, and confirms the install script works.

- [ ] **Step 1: Push all commits**

```bash
git push origin master
```

- [ ] **Step 2: Tag and push v0.1.0**

```bash
git tag v0.1.0
git push origin v0.1.0
```

- [ ] **Step 3: Watch the release pipeline**

Open: `https://github.com/thephilip/shem/actions`

Wait for the `Release` workflow to complete (typically 5–10 minutes). Confirm:
- All three build jobs go green
- The `release` job creates a GitHub Release at `https://github.com/thephilip/shem/releases/tag/v0.1.0`
- Three tarballs are attached: `shem-linux-x86_64.tar.gz`, `shem-macos-x86_64.tar.gz`, `shem-macos-arm64.tar.gz`

- [ ] **Step 4: Test the install script locally**

```bash
# Run the install script against the live release
curl -fsSL https://raw.githubusercontent.com/thephilip/shem/master/install.sh | bash
```

Expected final output:
```
shem v0.1.0 installed.

You're ready. Run `shem` to start.
```

Verify the binary is reachable:
```bash
~/.local/bin/shem version
# or, if ~/.local/bin is in PATH:
shem version
```

Expected: `shem 0.1.0`

- [ ] **Step 5: Verify README on GitHub**

Open `https://github.com/thephilip/shem` and confirm:
- `shem.png` banner renders
- CI badge shows green
- Install command is visible above the fold
- No broken links in the Roadmap section

---

## Version discipline note

`mix.exs` has `version: "0.1.0"`. The git tag (`v0.1.0`) must match this. For future releases: bump `version` in `mix.exs`, commit, then tag the commit. The release pipeline does not enforce this — it is a manual convention.
