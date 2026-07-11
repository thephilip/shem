# Authoring Tool Packs

Shem is a tool for control, not constraint. A pack declares what each tool
actually needs — network, a custom image, a host mount — and the operator sees
exactly that at install time and grants it deliberately, per tool. Nothing is
granted implicitly. If you declare nothing, your tool runs in the default
sandbox (`--network=none`, per-language slim image, read-only source mount),
which is safe to be lazy with: most tools need nothing else.

## Pack layout

```
my-pack/
├── pack.json            # {"name": "...", "version": "...", "tools": ["tool_id", ...]}
└── tools/
    ├── tool_id.json     # per-tool manifest (reference below)
    └── tool_id.py       # source (.py / .ts / .go / .ex per language)
```

`pack.json` names the pack and lists its tool ids. Each tool has a manifest
(`tools/<id>.json`) and a source file next to it. The manifest's `test_source`
is mandatory in practice: every tool is **re-gated locally at install** — its
tests run in a throwaway container on the installer's machine, and a tool that
fails its own tests is rejected. You are not asking users to trust your CI.

## Manifest reference (Pack Contract v2)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `language` | string | yes | `python`, `javascript`, `go`, or `elixir` |
| `description` | string | yes | shown to agents in the tool manifest |
| `schema` | object | no | JSON schema for the tool's args |
| `constraints` | list | no | property-test constraints (see graduation docs) |
| `test_source` | string | yes | test file contents, run at install in the gate container |
| `sandbox` | object | no | elevated profile request — see below |
| `actions` | list | no | `[{"name": ..., "risk": ...}]` — see below |

All four languages run under the same contract — including Elixir, which
graduates and runs as a containerized `:port` runtime like the rest (Phase 6):
`sandbox:` profiles apply, secret handles resolve at invocation, and pack
Elixir never compiles into the host BEAM.

**`sandbox`** — omit it and your tool runs in the default profile. Fields:

- `network` (boolean, default `false`) — `true` removes `--network=none`.
- `image` (string) — replaces the default per-language slim image
  (fully qualified, e.g. `docker.io/mcr.microsoft.com/playwright/python:v1.44`).
- `mounts` (list of `{"host", "container", "mode"}`) — extra volume mounts;
  `mode` is `"ro"` (default) or `"rw"`. `host` may use `~`.

Any of these present (or a `rw` mount) makes the profile *elevated*.

**`actions`** — for dispatch-style tools (one tool, many verbs via an
`"action"` arg). Each entry declares `name` and `risk`:

- `read` — no side effects outside the container,
- `write` — mutates data reachable through its grants,
- `execute` — runs arbitrary code or commands.

Declared actions are enforced fail-closed at call time: an action the manifest
doesn't declare is blocked, and operators can deny individual actions by name.

## The consent flow

**As an author:** declare your real needs. An undeclared elevation isn't a
loophole — your tool simply runs without it (no network, default image, no
mounts) and fails. An *overstated* risk tag costs you nothing; an understated
one lowers your tool's trust score at review.

**As an operator:** installing a pack with elevated tools and no grants
rejects those tools with a structured report of exactly what each requested:

```
rejected: [%{id: "browser", reason: "needs_consent",
             requested: %{"network" => true, "image" => "docker.io/..."}}]
```

Grant per tool id: `shem-install <url> --grant browser` (CLI), `"grants":
["browser"]` (REST `POST /packs` / MCP `install_pack`). The grant is recorded
in the tool's tagged manifest (`granted` key) and applied every time the tool
runs. Reinstalling — including pack upgrades — re-requires consent: grants
name tool ids at one install, they do not survive a reinstall unseen.

## Secret handles

Tools that need credentials never receive them through the log. An agent (or
caller) passes a *handle*:

```json
{"token": {"$secret": "github_api_key"}}
```

At execution time — after the args have been appended to the EventLog — Shem
resolves each handle through the configured provider tool
(`config :shem, :secret_provider, "secret_store"`). The provider is invoked
with `%{"action" => "read", "key" => key}` and must return the plaintext as a
binary — bare, wrapped as `{"$sensitive": <binary>}`, or nested under a
`"value"` key (so a provider may return its full read result). The
plaintext is spliced into the executor-bound args only; the EventLog, the
model context, and any attest bundle keep the handle. Resolution failure fails
the whole tool call — a tool never runs with a half-resolved arg set.

For sensitive *outputs*, wrap the value: a result containing
`{"$sensitive": value}` is redacted at append time to
`{"$redacted": <sha256-16>}` **before hashing**, so the chain commits to the
redacted form and verify/replay/attest all still pass. The digest is
deterministic: the same secret redacts to the same marker, so replays compare.

## Action policy

Host-wide: `config :shem, :tool_policy, %{deny: ["browser.evaluate", "shell"]}`
— `tool` denies the whole tool, `tool.action` denies one action. Per-agent:
`spawn_agent(..., policy: %{deny: [...]})` unions with the host policy.
Undeclared actions are blocked fail-closed regardless of policy.

## Known limits

- A granted tool can still misbehave *within* its grant — a network grant is a
  network grant. Grants bound the blast radius; they don't audit intent.
- Risk tags are advisory. They feed the hardening review and the operator's
  decision; they are not enforced semantics.
## Pre-publish checklist

- [ ] Declare your real sandbox profile — nothing more, nothing less.
- [ ] One README line on first-run downloads: what, from where, how big.
- [ ] Mark sensitive outputs with `{"$sensitive": ...}`.
- [ ] Declare every action with an honest risk tag.
- [ ] Reference packs to copy from: **shem-browser-tools**,
      **shem-secret-tools**, **shem-knowledge-tools**.
