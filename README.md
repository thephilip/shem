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
    <img src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" alt="Apache 2.0 License">
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

Apache 2.0 — see [LICENSE](LICENSE).
