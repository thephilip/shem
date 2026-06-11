# Phase 33: CLI, Config & First-Run Experience

## Goal

Give shem a real command-line interface, a user-editable YAML config file, and a polished first-run experience. A new user who installs shem should know exactly what to do next without reading documentation.

## Background

After Phase 32, shem installs correctly on supported platforms but has three UX problems:

1. **No CLI** — running `shem` with no arguments starts the server with no explanation. There is no help text, no version command, no way to discover what the tool does.
2. **No user config** — LLM routes are baked in at compile time (`prod.exs`). A new user has no way to configure their LLM backend without modifying source and rebuilding.
3. **Bad first-run** — if no LLM is configured, shem crashes with OTP error output rather than guiding the user to set one up.

---

## Command Surface

The installed `~/.local/bin/shem` wrapper dispatches based on its first argument:

| Invocation | Behaviour |
|---|---|
| `shem` | Print help and exit 0 |
| `shem --help` / `-h` | Print help and exit 0 |
| `shem start` | Start shem with TUI |
| `shem start --headless` | Start shem without TUI (HTTP/MCP API only) |
| `shem setup` | Interactive first-run configuration wizard |
| `shem config list` | Print all current config values |
| `shem config get <key>` | Print a single config value |
| `shem config set <key> <value>` | Write a config value and save |
| `shem status` | Probe running instance and show service state |
| `shem upgrade` | Upgrade to latest release |
| `shem version` | Print installed version |
| `shem <unknown>` | Print "unknown command", show help, exit 1 |

`setup`, `config`, `status`, and `version` run via `bin/shem eval` — they start a minimal VM without booting the full supervision tree, so they work whether or not shem is already running.

`upgrade` lives entirely in the wrapper script (bash) since it replaces the binary itself.

---

## YAML Config File

**Location:** `~/.config/shem/config.yaml`

Created by `shem setup`. Read at startup via `runtime.exs` using `yaml_elixir`. If the file does not exist, shem falls back to environment variables then compiled defaults.

**Schema:**

```yaml
llm:
  default:
    backend: anthropic          # anthropic | openai | ollama | llama_cpp
    model: claude-sonnet-4-6
    api_key: ""                 # leave blank to use ANTHROPIC_API_KEY / OPENAI_API_KEY
    url: ""                     # required for ollama / llama_cpp (e.g. http://localhost:11434)

server:
  port: 4000
  host: 127.0.0.1              # set to 0.0.0.0 for network/server deployments

executor:
  backend: auto                 # auto | local | container
  image: debian:12-slim

tui: true                       # false = headless; overridden by --headless flag

data_dir: ~/.config/shem
```

**Mapping to app config:**

| YAML key | App config key |
|---|---|
| `llm.default.backend` + `llm.default.model` | `:llm_routes` → `%{default: {backend, model}}` |
| `llm.default.api_key` | Injected into transport opts (not written to app env) |
| `llm.default.url` | `:llm_llama_cpp_url` / `:llm_ollama_url` |
| `server.port` | `:mcp_port` |
| `server.host` | `:mcp_host` |
| `executor.backend` | `:executor_backend` |
| `executor.image` | `:executor_image` |
| `tui` | `:start_tui` |
| `data_dir` | `:trust_store_path`, `:preset_store_path`, `:memory_store_path`, `:event_log_path` |

The `api_key` field is read from the YAML at runtime and passed directly to the transport — it is never written to the application environment to avoid leaking it through `:application.get_all_env`.

**`shem config` key format:** dot-notation mirrors the YAML structure. `shem config set llm.default.backend openai` writes `llm → default → backend: openai` in the file, preserving all other keys.

---

## First-Run Detection

`runtime.exs` checks for a configured LLM after loading the YAML file:

- If `~/.config/shem/config.yaml` exists and `llm.default.backend` is set → proceed normally.
- If no YAML but `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` is set in the environment → proceed with inferred config (anthropic, default model).
- Otherwise → print the message below and `System.halt(1)`:

```
✦ Shem is not configured yet.

  Run `shem setup` to configure your LLM backend, or set
  ANTHROPIC_API_KEY (or OPENAI_API_KEY) in your environment
  and re-run `shem start`.

  Docs: https://github.com/thephilip/shem
```

No crash dump. No OTP supervisor errors. Clean exit.

---

## `shem setup` Wizard

Implemented in `Shem.CLI.Setup`. Runs via `bin/shem eval "Shem.CLI.Setup.run()"`.

Uses ANSI escape codes for color and spinner animation (no external dependency — hand-rolled). Detects 24-bit color support via `$COLORTERM`; falls back to plain text if unset.

**Flow:**

```
✦ Welcome to Shem
─────────────────────────────────────────────────────

  Existing config found at ~/.config/shem/config.yaml
  Overwrite? [y/N] →

Step 1/3 — LLM Backend
  Which provider will you use?
  [1] Anthropic   (claude-sonnet-4-6)
  [2] OpenAI      (gpt-4o)
  [3] Ollama      (local — http://localhost:11434)
  [4] llama.cpp   (local — http://localhost:1234)
  → 1

Step 2/3 — API Key
  ANTHROPIC_API_KEY is already set in your environment.
  Use it? [Y/n] → Y

Step 3/3 — Server
  Port [4000]: →
  Host [127.0.0.1]: →

✦ Testing connection to Anthropic...  ✓
✦ Writing ~/.config/shem/config.yaml...  ✓

─────────────────────────────────────────────────────
Setup complete. Run `shem start` to launch.
```

**Rules:**

- If a relevant env var exists (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`), offer to use it without re-entry.
- The `url` prompt is shown only for `ollama` and `llama_cpp` backends.
- API key validation: makes a minimal real request (e.g. list models or a 1-token prompt) before writing the config. If validation fails, explains why and re-prompts — it never writes a broken config.
- If the user aborts mid-wizard (`Ctrl+C`), nothing is written.

---

## `shem status`

Implemented in `Shem.CLI.Status`. Runs via `bin/shem eval "Shem.CLI.Status.run()"`.

Probes `http://localhost:<port>/api/routes` (or a dedicated `GET /api/health` endpoint added in this phase). Does not connect to the running BEAM node — pure HTTP probe.

**Output when running:**

```
Shem v0.1.1

  HTTP / MCP   ● running   127.0.0.1:4000
  LLM backend  ● anthropic  claude-sonnet-4-6
  Agents        2 active
  TUI           off (headless)
```

**Output when not running:**

```
Shem v0.1.1

  ○ not running
```

The `/api/health` endpoint returns a JSON object:

```json
{
  "version": "0.1.1",
  "tui": false,
  "llm_backend": "anthropic",
  "llm_model": "claude-sonnet-4-6",
  "active_agents": 2,
  "host": "127.0.0.1",
  "port": 4000
}
```

---

## ANSI Banner

`shem.png` is converted to ANSI half-block art (▀▄ with 24-bit color) at development time using a one-off Python script (`scripts/generate_banner.py`). The output is stored as `priv/static/banner.ansi` and embedded as a compile-time string in `Shem.CLI.Banner`.

The banner prints at the top of `shem --help` and `shem setup`. Skipped when `$COLORTERM` is not `truecolor` or `24bit`, or when stdout is not a TTY.

**Banner generation script** (run once by a developer, output committed):

```python
# scripts/generate_banner.py
# Usage: python scripts/generate_banner.py shem.png priv/static/banner.ansi
# Requires: pip install Pillow
from PIL import Image
import sys

img = Image.open(sys.argv[1]).convert("RGB")
width = 40  # characters wide
ratio = img.height / img.width
height = int(width * ratio * 0.55)  # terminal cells are ~2x taller than wide
img = img.resize((width, height * 2))

lines = []
for y in range(0, height * 2, 2):
    line = ""
    for x in range(width):
        r1, g1, b1 = img.getpixel((x, y))
        r2, g2, b2 = img.getpixel((x, y + 1))
        line += f"\x1b[38;2;{r1};{g1};{b1}m\x1b[48;2;{r2};{g2};{b2}m▀"
    line += "\x1b[0m"
    lines.append(line)

with open(sys.argv[2], "w") as f:
    f.write("\n".join(lines) + "\n")
```

---

## Install Script Polish

The existing `install.sh` is enhanced with visible progress for each step:

```
Shem Installer
──────────────────────────────────────────────────

✦ Checking system requirements (OpenSSL 3.x)...  ✓
✦ Fetching latest release...  v0.1.1
  Downloading shem-linux-x86_64.tar.gz
  ████████████████░░░░  80%
✦ Extracting...  ✓
✦ Installing to ~/.local/bin/shem...  ✓
✦ Verifying (crypto + boot check)...  ✓

──────────────────────────────────────────────────
Shem v0.1.1 installed.

Next step: run `shem setup` to configure your LLM backend.
```

Progress bar uses `curl --progress-bar` output reformatted via `awk`. Each step name prints first, then `✓` or an error message on completion. On failure, the failing step explains what went wrong with a platform-specific fix hint.

---

## New/Modified Files

| File | Change |
|---|---|
| `install.sh` | Progress bar, polish, ends with `shem setup` prompt |
| `~/.local/bin/shem` (wrapper) | Full command dispatcher replacing `start`-only logic |
| `lib/shem/cli/banner.ex` | ANSI banner embed + TTY/color detection |
| `lib/shem/cli/setup.ex` | Interactive setup wizard |
| `lib/shem/cli/config.ex` | `list` / `get` / `set` subcommands, YAML read/write |
| `lib/shem/cli/status.ex` | HTTP probe + formatted output |
| `lib/shem/rest/handlers/health.ex` | `GET /api/health` endpoint |
| `lib/shem/rest/router.ex` | Forward `/health` to health handler |
| `config/runtime.exs` | YAML config loading, first-run detection, env-var fallback |
| `mix.exs` | Add `yaml_elixir` dependency |
| `priv/static/banner.ansi` | Pre-generated ANSI art (committed) |
| `scripts/generate_banner.py` | One-off banner generation script (committed) |

---

## Out of Scope (Phase 33b / later)

- Config editor in the TUI
- Config editor in the Web UI
- `shem upgrade` with rollback
- Per-preset LLM routing via `shem config set`
- Windows support

---

## Success Criteria

1. `shem` with no arguments prints help with the ANSI banner and command reference — no server starts.
2. `shem start` refuses to start if no LLM is configured, prints a one-line fix.
3. `shem setup` walks a new user through LLM selection, validates the key, and writes `~/.config/shem/config.yaml`.
4. `shem start` after setup starts cleanly with the configured backend.
5. `shem status` correctly reports running/not-running and active agent count.
6. `shem upgrade` fetches and installs the latest release, skips if already current.
7. The install script shows visible progress and ends with "run `shem setup`".
8. The ANSI banner renders correctly in truecolor terminals and is suppressed in non-TTY / non-truecolor environments.
