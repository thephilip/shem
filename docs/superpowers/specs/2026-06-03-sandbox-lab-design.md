# Phase 3: Sandbox Framework (Lab) — Design Spec

**Date:** 2026-06-03
**Status:** Approved

---

## 1. Scope

Phase 3 builds the infrastructure for safe, supervised Elixir code execution and a formal graduation gate for agent-written tools. Polyglot runtimes (Python, TypeScript via BEAM Ports) are explicitly deferred. Lab git versioning is explicitly deferred.

The six deliverables:

1. **`Shem.Tool`** — struct: the data contract for a graduated tool
2. **`Shem.Lab.Workspace`** — pure module: path management and disk I/O for the lab directory
3. **`Shem.Lab.Executor`** — supervised execution harness: compile, load, run, clean up
4. **`Shem.Lab.GraduationGate`** — StreamData property test runner: pass → graduate, fail → structured feedback
5. **`Shem.Lab.Registry`** — ETS-backed GenServer: scans graduated tools on boot, exposes lookup API
6. **TUI** — dashboard stat line: `Tools: N graduated`

---

## 2. Data Model

```elixir
%Shem.Tool{
  id: String.t(),            # slug identifier, e.g. "parse_csv_v1"
  name: String.t(),          # human-readable name
  module: atom(),            # compiled module atom, e.g. ParseCsv
  source: String.t(),        # .ex source the agent wrote
  test_source: String.t(),   # StreamData property tests the agent wrote
  constraints: [String.t()], # user-provided constraints (stored as metadata)
  graduated_at: DateTime.t(),
  metadata: map()            # agent_id, attempt_count, etc.
}
```

A tool only becomes a `Shem.Tool` struct at the moment of graduation. Before that, it is represented as plain source strings. The struct is the contract for Phase 4's LLM-facing API.

---

## 3. File Layout

```
lib/shem/
  tool.ex
  lab/
    workspace.ex
    executor.ex
    graduation_gate.ex
    registry.ex
```

Lab data on disk:

```
~/.config/shem/lab/
  messy/      # scratch area — agent writes here during iteration
  graduated/  # source of truth — one <id>.ex file per graduated tool
```

Test config overrides `lab_dir` to `tmp/test_lab` so tests never touch `~/.config/shem`.

---

## 4. Execution Model

`Shem.Lab.Executor` is a pure function module (no GenServer state). All execution happens inside a `Task` owned by `Shem.Lab.TaskSupervisor`, which is added to the supervision tree.

**Public API:**

```elixir
Executor.run(source, fun, opts \\ [])
# source  :: String.t()       — Elixir source defining one module
# fun     :: (atom() -> any()) — receives the loaded module atom, returns a value
# opts    :: [timeout: ms]    — default 5000
# returns :: {:ok, value} | {:error, :compile, reason}
#          | {:error, :timeout} | {:error, :runtime, {exception, stacktrace}}
```

**Steps:**

1. `Code.compile_string(source)` → `[{module, bytecode}]`
2. `:code.load_binary(module, ~c"nofile", bytecode)`
3. `fun.(module)` runs inside a supervised Task with timeout
4. `:code.purge(module)` + `:code.delete(module)` — always, regardless of outcome

**Return values:**

| Result | Tagged tuple |
|---|---|
| Success | `{:ok, value}` |
| Compile error | `{:error, :compile, reason}` |
| Timeout | `{:error, :timeout}` |
| Runtime crash | `{:error, :runtime, {exception, stacktrace}}` |

Default timeout: 5 seconds. Configurable via `config :shem, executor_timeout_ms: N`.

---

## 5. Graduation Gate

`Shem.Lab.GraduationGate` orchestrates the full compile → test → graduate flow.

**Input:** `{source, test_source, constraints}` — all strings from the agent, constraints optionally injected by the user.

**Flow:**

1. Executor compiles and loads the source module
2. Executor compiles and loads the test module
3. `ExUnit.run/0` executes the test module inside a supervised Task
4. **All pass** → `Workspace.graduate(tool)` writes `graduated/<id>.ex` → Registry.register(tool) → `{:ok, %Shem.Tool{}}`
5. **Any fail** → `{:error, :gate, failures}` — ExUnit failure structs returned intact so the agent sees the violated property
6. **Compile error** → `{:error, :compile, reason}` — propagated from Executor

**Naming contract:** The agent names its implementation module (e.g. `ParseCsv`); the test module must be named `<ModuleName>Test` (e.g. `ParseCsvTest`). The gate enforces this convention. The tool `id` is derived from the module name: `ParseCsv` → `"parse_csv"`. If a tool with that id already exists in the registry, the gate appends `_v2`, `_v3`, etc.

**Timestamp:** GraduationGate sets `graduated_at: DateTime.utc_now()` on the `%Shem.Tool{}` struct before calling `Registry.register/1`.

User-supplied constraints are stored on `%Shem.Tool{}.constraints` — they are not mechanically enforced by the gate. The agent is responsible for writing tests that encode them.

---

## 6. Workspace

`Shem.Lab.Workspace` is a pure module (no process).

**Public API:**

- `messy_path(id)` → absolute path under `lab/messy/`
- `graduated_path(id)` → absolute path under `lab/graduated/`
- `graduate(tool)` → writes `tool.source` to `graduated/<id>.ex`, returns `:ok`
- `list_graduated()` → returns list of `{id, path}` tuples for all `.ex` files in `graduated/`

Lab root defaults to `~/.config/shem/lab/`. Overridden by `config :shem, lab_dir: "..."`.

---

## 7. Registry

`Shem.Lab.Registry` is a GenServer backed by ETS.

**Boot sequence (`init/1`):**

1. Creates ETS table
2. Calls `Workspace.list_graduated/0`
3. For each path, reads source, compiles and loads via Executor, constructs `%Shem.Tool{}`, inserts into ETS

**Public API:**

- `Registry.lookup(id)` → `{:ok, %Shem.Tool{}}` or `{:error, :not_found}`
- `Registry.all()` → `[%Shem.Tool{}]`
- `Registry.register(tool)` → inserts into ETS (called by GraduationGate after successful graduation)

Added to `Shem.Application` supervision tree alongside `Shem.EventLog`.

---

## 8. TUI

The Dashboard view gets a new stat line sourced from `Registry.all/0`:

```
Tools: 3 graduated
```

Populated on the existing 500ms subscription tick — no new subscription needed.

---

## 9. Testing

Test config: `config :shem, lab_dir: "tmp/test_lab"` — no disk side effects in `~/.config/shem`.

| Module | Key test cases |
|---|---|
| `Shem.Tool` | Struct construction, field defaults |
| `Shem.Lab.Workspace` | Path helpers return correct strings; `graduate/1` writes file; `list_graduated/0` finds it |
| `Shem.Lab.Executor` | Successful run; compile error; runtime crash; timeout (infinite loop source + short deadline) |
| `Shem.Lab.GraduationGate` | Passing properties → `:ok` + file written; failing property → `{:error, :gate, failures}`; compile error in test source propagated |
| `Shem.Lab.Registry` | Starts empty; `register/1` → findable via `lookup/1` and `all/0`; boot scan loads pre-written `.ex` from graduated dir |

---

## 10. What This Phase Does NOT Include

- Polyglot runtimes (Python, TypeScript) — deferred, will use BEAM Ports
- Lab git versioning — deferred to when agents run self-improvement loops
- Live hot-reload of graduated tools — scan-on-boot only
- LLM integration — Phase 4
- Agent authoring of tools — Phase 4 (this phase builds the infrastructure those agents call into)
