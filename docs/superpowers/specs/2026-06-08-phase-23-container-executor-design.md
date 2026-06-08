# Phase 23 — Container Executor Design

## Goal

Replace the unsandboxed `shell` tool execution with a container-based executor (Podman preferred, Docker fallback) while keeping `run_code` in-BEAM for Elixir tool graduation. Introduce a `Backend` behaviour abstraction that accommodates a future K8s backend without changes to `ToolDispatch` or the behaviour contract.

## Background

`ToolDispatch.dispatch_builtin("shell", ...)` currently calls `System.cmd("sh", ["-c", cmd])` directly on the host — no isolation, no resource limits, full filesystem and process access. This is the `# TODO(phase-9b)` left in the codebase since Phase 9.

`run_code` compiles Elixir source into the running BEAM node via `Code.compile_string`. This tight coupling is intentional: graduated tools interact with Shem's own internals (`Lab.Registry`, `EventLog`, etc.) during testing. It stays in-BEAM.

## Execution Model

Two distinct execution surfaces with different purposes:

| Tool | Execution | Access to Shem internals | Purpose |
|---|---|---|---|
| `run_code` (Elixir) | In-BEAM (unchanged) | Yes | Shem tool authoring + graduation |
| `shell` | Container (new) | No | User project work |

The container path handles all user project work — building repos, running test suites, data processing, invoking any language runtime. The container image is the dependency declaration: agents working with Python use `python:3.12-slim`, no local Python installation required.

## Architecture

### New modules

```
lib/shem/lab/executor/
  backend.ex                  ← behaviour
  backend/
    local.ex                  ← System.cmd (current behaviour, unchanged)
    container.ex              ← Podman/Docker invocation
```

### Modified modules

- `lib/shem/lab/executor.ex` — adds `run_shell/3` public function; existing `run/3` (`run_code`) untouched
- `lib/shem/agent/tool_dispatch.ex` — `dispatch_builtin("shell", ...)` calls `Lab.Executor.run_shell/3`
- `lib/shem/application.ex` — emits startup warning when `:auto` resolves to `:local`
- `config/config.exs` — adds `executor_backend` and `executor_image` keys
- `config/test.exs` — pins `executor_backend: :local`

### Backend behaviour

```elixir
defmodule Shem.Lab.Executor.Backend do
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @callback run_shell(cmd :: String.t(), timeout_ms :: non_neg_integer(), opts :: keyword()) ::
              result()
end
```

### Runtime resolution

At startup, `Application.start/2` resolves and caches the active backend:

```
executor_backend: :auto   → detect podman → detect docker → :local (+ startup warning)
executor_backend: :local  → Local backend unconditionally
executor_backend: :container → Container backend unconditionally (fails loudly if no runtime)
```

The startup warning (emitted once, not per shell call):

```
[warning] Shem: no container runtime found (tried podman, docker).
          Shell tool will run without isolation. Install podman or docker to enable sandboxed execution.
```

### Container invocation

```
podman run --rm -i [--network=<policy>] <image> sh -c "<cmd>"
```

- `--rm` — auto-remove on exit, no container debris
- `-i` — stdin open (required by some tools)
- `--network` — defaults to container default networking (allows internet access for `git clone`, `pip install`, etc.); configurable via `executor_network: :default | :none | :host`
- No volume mounts in Phase 23 (stateless per invocation)

`docker` is substituted for `podman` when only Docker is found.

### Configuration

```elixir
# config/config.exs
config :shem,
  executor_backend: :auto,         # :auto | :local | :container
  executor_image: "debian:12-slim", # default container image
  executor_network: :default        # :default | :none | :host

# config/test.exs
config :shem,
  executor_backend: :local          # no container runtime needed in CI
```

## Error Handling

| Condition | Return value |
|---|---|
| Exit 0 | `{:ok, output}` |
| Non-zero exit | `{:error, "exit <code>: <output>"}` |
| Timeout | `{:error, "timeout after <N>ms"}` |
| Image not found | `{:error, "..."}` (container runtime's own message, surfaced as-is) |
| Runtime not found (`:container` explicit) | `{:error, "no container runtime available: ..."}` on every shell call; error log emitted once at startup |
| Runtime not found (`:auto`) | falls back to `:local` with startup warning |

Timeout enforcement: `Task.yield/2` + `Task.shutdown(:brutal_kill)` on the spawned process. The `--rm` flag ensures the container is removed even if the host process is killed.

## Testability

`Backend.Container` accepts a `run_fn:` injectable opt (pattern established by `OpenAITransport.http_post_fn:`). Default is the real Podman/Docker CLI invocation. Tests inject a mock:

```elixir
run_fn = fn cmd, _timeout, _opts -> {:ok, "mocked output"} end
Container.run_shell("ls", 5_000, run_fn: run_fn)
```

Test environment uses `executor_backend: :local` — no container runtime needed in CI.

## Data Flow

```
Agent calls shell tool
  → ToolDispatch.dispatch_builtin("shell", args)
    → Lab.Executor.run_shell(cmd, timeout_ms, [])
      → resolved Backend.run_shell(cmd, timeout_ms, opts)
        → [Local] System.cmd("sh", ["-c", cmd])
        → [Container] podman run --rm -i <image> sh -c "<cmd>"
      → {:ok, output} | {:error, reason}
    → formatted tool result string
  → agent receives tool output
```

## Testing Strategy

- **`Backend.Container` unit tests** — `run_fn:` injection covers: success, non-zero exit, timeout, image-not-found error message passthrough
- **`Executor.run_shell/3` tests** — backend routing verified via `Process.put(:shem_executor_backend, ...)` override (mirrors `:shem_replay_pipeline` pattern)
- **`ToolDispatch` shell tests** — existing tests unchanged; run against `:local` backend; verify `run_shell/3` is called (not `System.cmd` directly)
- **Startup warning test** — assert `Logger.warning` emitted when `:auto` resolves to `:local`

## Future Work (Phase N+1)

The following are explicitly out of scope for Phase 23 but designed-for by the Backend abstraction:

**Per-session workspace** — a named volume mounted at `/workspace` in a long-lived container per agent session. Shell calls share a working directory across a turn, enabling patterns like `cd repo && run tests` without re-cloning between calls. Requires `Container` backend to track a container-per-session-id rather than spawning fresh per call.

**Pre-warmed container pool** — containers ready to accept work immediately, eliminating cold-start latency on the first shell call of a turn.

**Resource limits** — `--memory` and `--cpus` caps per invocation. Configurable globally and per-call.

**Network policy per-tool** — override `executor_network` at the individual tool call level (e.g., graduated tools can declare `network: :none`).

**K8s backend** — `Shem.Lab.Executor.Backend.K8s` — third implementation of the `Backend` behaviour. Creates a K8s Job per shell invocation, streams logs, cleans up. For users running Shem in a cluster. `LIBCLUSTER_STRATEGY=dns` already works for K8s headless services. Shem drives K8s; K8s does not orchestrate Shem.

**Polyglot `run_code`** — extend `run_code` with a `language:` parameter; non-Elixir source routes to the Container backend with an appropriate image (`python:3.12-slim`, `node:22-alpine`, etc.). Elixir source continues in-BEAM unchanged.
