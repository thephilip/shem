# Phase 29: README + Install Script

## Goal

Make Shem presentable and installable for a public audience. A developer who lands on the GitHub repo should immediately understand what Shem is, why it's different, and be running it within two minutes.

---

## README

### Angle

Lead with the single differentiator no competitor can claim: **debuggability**. Every Python-based agent framework is a black box when something goes wrong. Shem's replayable event log, BEAM supervision, and structured audit trail make it observable in a way LangChain, CrewAI, and Hermes cannot replicate.

One-line hook (also the GitHub repo description):

> The first AI agent platform you can actually debug.

### Structure

```
[shem.png banner]

# shem

> The first AI agent platform you can actually debug.

[install badge]  [license badge]  [CI badge]

---

Shem is a general-purpose AI agent platform that runs on your machine.
Ask it to review your code, research a topic, draft a document, or audit
a security posture — then watch exactly what it did and why, turn by turn,
with a replayable event log no Python-based framework can match.

Works with Claude, ChatGPT, Ollama, llama.cpp, and any OpenAI-compatible API.

## Install
## Why Shem?
## Quick start
## Presets
## Docker
## Build from source
## Roadmap
## License
```

### Section: Install

```bash
curl -fsSL https://raw.githubusercontent.com/thephilip/shem/master/install.sh | bash
```

Followed by the Docker alternative:

```bash
docker run ghcr.io/thephilip/shem:latest
```

### Section: Why Shem?

Three differentiators, each one sentence:

**Debuggable.** Every LLM call, tool use, and agent decision is logged, replayable, and forkable. When something goes wrong, you find out why.

**Real concurrency.** Built on the BEAM (Erlang VM). Agents run as supervised OTP processes — no GIL, no asyncio, no mystery crashes.

**Not just for coding.** Six built-in presets: general, coder, researcher, writer, security, explorer. Switch mid-conversation with `/preset <name>`.

### Section: Quick start

Three steps after install:

1. Run `shem` in any project directory
2. Ask it anything — it detects your project type automatically
3. Type `/help` to see all available commands

### Section: Presets

A table:

| Preset | Purpose |
|--------|---------|
| `general` | Conversational assistant. The default. |
| `coder` | Code reading, writing, refactoring, debugging. |
| `researcher` | Information synthesis, summarisation, structured notes. |
| `writer` | Drafting, editing, tone adjustment, structure. |
| `security` | Vulnerability identification, threat modelling. Conservative tool access. |
| `explorer` | Codebase and filesystem exploration. Read-only. |

Switch mid-conversation: `/preset coder`

Create your own: `/hire <name> <role description>`

### Section: Docker

```bash
docker run -it --rm \
  -v "$PWD":/workspace \
  -e SHEM_LLM_URL=http://host.docker.internal:11434 \
  ghcr.io/thephilip/shem:latest
```

### Section: Build from source

```bash
git clone https://github.com/thephilip/shem
cd shem
mix deps.get
mix run --no-halt   # dev mode
# or
MIX_ENV=prod mix release
./_build/prod/rel/shem/bin/shem start
```

Requires: Elixir 1.19+, OTP 29+.

### Section: Roadmap

Link to `docs/superpowers/specs/2026-06-08-roadmap-phases-28-36-design.md`.

### Section: License

MIT. (License file to be added as part of this phase.)

### Visual asset

`shem.png` is used as the README banner/logo. A terminal GIF demo is deferred to a later phase once the UI is stable.

---

## Install Script (`install.sh`)

Lives at the repo root. Referenced directly from the README curl command.

### Behaviour

1. Detect OS (`uname -s`) and architecture (`uname -m`)
2. Map to one of three supported targets:
   - `Linux-x86_64` → `shem-linux-x86_64.tar.gz`
   - `Darwin-x86_64` → `shem-macos-x86_64.tar.gz`
   - `Darwin-arm64` → `shem-macos-arm64.tar.gz`
3. Fetch the latest release tag from the GitHub API
4. Download the matching tarball from GitHub Releases
5. Extract `bin/shem` to `~/.local/bin/`
6. Run `shem --version` as a smoke test
7. Print `You're ready. Run \`shem\` to start.`
8. If `~/.local/bin` is not in PATH, print a hint

### Error handling

- Unsupported platform → print message + build-from-source URL + exit 1
- Download failure → curl exits non-zero, `set -euo pipefail` propagates
- Smoke test failure → explicit error message + exit 1

### Security properties

- `set -euo pipefail` — fails fast, no silent partial installs
- No `sudo` — installs to user-local `~/.local/bin`
- No eval of downloaded content beyond the tarball extraction
- Binary verified runnable before declaring success

---

## CI Release Pipeline (`.github/workflows/release.yml`)

### Trigger

```yaml
on:
  push:
    tags: ["v*"]
```

Pushing a tag like `v0.1.0` triggers the pipeline. The tag must match the `version` field in `mix.exs`.

### Jobs

**build-linux** (`ubuntu-latest`): setup-beam → `MIX_ENV=prod mix release` → tar `bin/shem` + OTP runtime → upload artifact `shem-linux-x86_64.tar.gz`

**build-macos-intel** (`macos-13`): same steps → `shem-macos-x86_64.tar.gz`

**build-macos-arm64** (`macos-14`): same steps → `shem-macos-arm64.tar.gz`

**release** (`ubuntu-latest`, needs all three build jobs):
- Download all three artifacts
- `gh release create ${{ github.ref_name }} *.tar.gz --title "Shem ${{ github.ref_name }}" --generate-notes`
- Requires `permissions: contents: write`

### Tarball structure

```
shem-<platform>.tar.gz
└── bin/
    └── shem          ← the executable
└── releases/
    └── ...           ← OTP runtime files
```

The install script extracts with `--strip-components=2 bin/shem` to get just the binary. No Elixir or Erlang installation required on the user's machine — the OTP runtime is bundled.

### Version discipline

`mix.exs` `version:` and the git tag must stay in sync. The release pipeline does not enforce this automatically — it is a manual convention. The implementation plan should include a note about this.

---

## What this phase does NOT include

- A hosted domain (`install.shem.sh`) — the raw GitHub URL is sufficient for now
- A terminal GIF/recording — deferred until the UI is stable
- Windows support — out of scope
- Hex.pm package publishing — Shem is a platform, not a library
- Automated version bumping — manual tagging is sufficient at this scale
