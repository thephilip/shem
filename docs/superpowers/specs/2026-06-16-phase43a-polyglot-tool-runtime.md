# Phase 43a — Polyglot Tool Runtime Design Spec
_2026-06-16_

## Problem

Shem's tool runtime is Elixir-only. `write_tool` graduates Elixir modules into the BEAM. `dispatch_lab` calls `tool.module.run(args)`. `Tool.module` is `@enforce_keys`. Three dispatch sites pattern-match on it. The entire Lab stack assumes Elixir.

Two additional gaps discovered during design:

1. **Metadata lost on restart.** `Workspace.graduate` writes only `tool.source` to `graduated/{id}.ex`. On restart, `scan_graduated` reconstructs `%Tool{}` via source regex — losing `description`, `schema`, `constraints`, `test_source`. Phase 42 graduated tools reappear in the manifest with `"graduated tool: <name>"` after every restart.

2. **Container backend doesn't mount files.** `Backend.Container.build_args` runs `podman run --rm -i <image> sh -c <cmd>` with no `-v` volume mount. The host filesystem is invisible inside the container. Python graduation cannot pass source files to the container without an explicit mount.

## Goal

Make the tool runtime language-agnostic. After this phase:

- `write_tool` accepts `language: "python"` and graduates a Python tool
- The graduated tool is callable by agents via `dispatch_lab` and MCP
- Calls are handled by a supervised BEAM Port pool (persistent local processes, JSON stdio)
- All tool metadata persists across restarts via a companion manifest file
- Elixir tools are unchanged in behaviour; the Elixir path is preserved exactly

This phase does NOT include the `python_toolsmith` preset — that is Phase 43b. A developer can graduate a Python tool manually after this phase; the agent-facing toolsmith UX comes in 43b.

## Scope

- Elixir toolchain: unchanged except `module:` → `runtime:` field rename
- Python graduation: pytest in container with volume mount
- Python runtime: local BEAM Ports (no container at runtime — tool vetted at graduation)
- Container backend: gains `mounts:` opt
- Workspace: manifest-based persistence for all metadata
- `write_tool`: gains `language:` field
- `GraduationGate`: language router, Python path added
- `PortPool`: new DynamicSupervisor tree, GenServer pool per tool
- `dispatch_lab` + MCP invoke handler: branch on `tool.runtime`
- Out of scope: `python_toolsmith` preset, JS/Rust/Go toolsmiths, Hypothesis property tests, PortPool per-session isolation, container runtime for Ports

## Architecture

### Data flow — Python tool graduation

```
write_tool(language: "python", source: "...", test_source: "...", description: "...")
  → dispatch_builtin("write_tool", args)
    → GraduationGate.run(source, test_source, language: "python", description: ...)
      → GraduationGate.Python.run(source, test_source, opts)
        → write source to /tmp/shem_grad_{id}/tool.py
        → wrap source in stdio loop → write to /tmp/shem_grad_{id}/tool_runtime.py
        → write test_source to /tmp/shem_grad_{id}/test_tool.py
        → Backend.Container.run_shell(
            "cd /workspace && pip install pytest -q && pytest test_tool.py -q",
            timeout,
            image: executor_image_python,
            mounts: [{"/tmp/shem_grad_{id}", "/workspace"}]
          )
        → on pass: Workspace.graduate(tool) → writes graduated/{id}_runtime.py + graduated/{id}.json
        → Lab.Registry.register(tool)  [runtime: {:port, path_to_runtime_py}]
        → {:ok, tool}
```

### Data flow — Python tool runtime call

```
agent calls tool "MyTool" with args %{"x" => 1}
  → dispatch_lab(tool_id, args)
    → tool = Registry.lookup(tool_id)
    → tool.runtime = {:port, "/path/to/graduated/my_tool_runtime.py"}
    → PortPool.call(tool.id, args)
      → check out idle worker Port (or queue if all busy)
      → send Jason.encode!(args) <> "\n" to Port stdin
      → read JSON line from Port stdout
      → Jason.decode!(line) → result
      → return worker to pool
    → {:ok, inspect(result)}
```

### Data flow — Elixir tool (unchanged)

```
dispatch_lab(tool_id, args)
  → tool.runtime = {:beam, MyModule}
  → ensure_loaded(tool)
  → MyModule.run(args)
```

## Components

### 1. `Shem.Tool` struct

```elixir
@enforce_keys [:id, :name, :runtime, :source, :test_source, :graduated_at]
defstruct [
  :id, :name, :runtime, :source, :test_source, :graduated_at,
  constraints: [], input_schema: %{}, metadata: %{}
]

@type runtime :: {:beam, module()} | {:port, String.t()}

@type t :: %__MODULE__{
  id: String.t(),
  name: String.t(),
  runtime: runtime(),
  source: String.t(),
  test_source: String.t(),
  constraints: [String.t()],
  input_schema: map(),
  graduated_at: DateTime.t(),
  metadata: map()
}
```

`module:` is removed from the struct and `@enforce_keys`. `runtime:` replaces it.

### 2. `Shem.Lab.Workspace`

**`graduate/1` — writes two files:**

For Elixir tools:
- `graduated/{id}.ex` — Elixir source (unchanged)
- `graduated/{id}.json` — manifest (new)

For Python tools:
- `graduated/{id}.py` — original Python source (for reference)
- `graduated/{id}_runtime.py` — source wrapped in stdio loop (what the Port actually runs)
- `graduated/{id}.json` — manifest

The stdio loop wrapper written to `{id}_runtime.py`:

```python
import sys
import json

{source}

if __name__ == "__main__":
    for line in sys.stdin:
        line = line.strip()
        if line:
            try:
                args = json.loads(line)
                result = run(args)
                print(json.dumps(result), flush=True)
            except Exception as e:
                print(json.dumps({"__error__": str(e)}), flush=True)
```

The manifest `{id}.json`:

```json
{
  "id": "my_tool",
  "name": "MyTool",
  "language": "python",
  "runtime_path": "/abs/path/graduated/my_tool_runtime.py",
  "description": "...",
  "schema": {},
  "constraints": [],
  "test_source": "...",
  "graduated_at": "2026-06-16T..."
}
```

**Manifest format — Elixir tools:**

```json
{
  "id": "my_elixir_tool",
  "name": "MyElixirTool",
  "language": "elixir",
  "description": "...",
  "schema": {},
  "constraints": [],
  "test_source": "...",
  "graduated_at": "2026-06-16T..."
}
```

No `runtime_path` field — the module name is already extractable from source and the BEAM path doesn't need a file path. `scan_graduated` extracts the module via regex as before, wraps it as `{:beam, ModuleName}`.

**`runtime_path/1` helper:**

```elixir
def runtime_path(id) do
  Path.join([priv_dir(), "graduated", "#{id}_runtime.py"])
  |> Path.expand()
end
```

Returns the absolute path to the runtime wrapper script. Used by `GraduationGate.Python` when building the tool struct and by `graduate/1` when writing the file.

**`scan_graduated/0` — manifest-first reconstruction:**

1. Scan `graduated/` for `*.json` manifest files
2. For each manifest:
   - `language: "elixir"` → extract module via regex from `graduated/{id}.ex`, synthesize `runtime: {:beam, module}`, populate metadata from manifest fields
   - `language: "python"` → use `"runtime_path"` from manifest directly, synthesize `runtime: {:port, runtime_path}`, populate metadata from manifest fields
3. Legacy fallback: for `*.ex` files with no companion manifest, use existing regex extraction and synthesize `runtime: {:beam, module}` with empty metadata — no data migration required

**`list_graduated/0` — updated to scan manifests, not `.ex` files.**

### 3. `Shem.Lab.Executor.Backend.Container`

Gains `mounts:` opt — a list of `{host_path, container_path}` tuples appended to `build_args` as `-v host:container:ro` flags:

```elixir
defp build_args(image, network, name, cmd, mounts) do
  mount_args = Enum.flat_map(mounts, fn {host, container} ->
    ["-v", "#{host}:#{container}:ro"]
  end)

  ["run", "--rm", "--name", name, "-i"] ++
    network_args(network) ++
    mount_args ++
    [image, "sh", "-c", cmd]
end
```

`run_shell/3` passes `Keyword.get(opts, :mounts, [])` through to `build_args`.

### 4. `Shem.Lab.GraduationGate`

`run/3` routes on `language:` opt:

```elixir
def run(source, test_source, opts \\ []) do
  case Keyword.get(opts, :language, "elixir") do
    "elixir" -> run_elixir(source, test_source, opts)
    "python" -> Shem.Lab.GraduationGate.Python.run(source, test_source, opts)
    lang      -> {:error, :unsupported_language, lang}
  end
end

defp run_elixir(source, test_source, opts) do
  # existing implementation, unchanged
end
```

**`Shem.Lab.GraduationGate.Python`** — new module:

```elixir
defmodule Shem.Lab.GraduationGate.Python do
  def run(source, test_source, opts) do
    id = unique_id(source)
    tmp_dir = Path.join(System.tmp_dir!(), "shem_grad_#{id}")
    File.mkdir_p!(tmp_dir)

    File.write!(Path.join(tmp_dir, "tool.py"), source)
    File.write!(Path.join(tmp_dir, "test_tool.py"), test_source)

    image = Application.get_env(:shem, :executor_image_python, "python:3.12-slim")
    timeout = Application.get_env(:shem, :executor_timeout_ms, 30_000)

    result = Shem.Lab.Executor.run_shell(
      "cd /workspace && pip install pytest -q --no-warn-script-location 2>/dev/null && pytest test_tool.py -q",
      timeout,
      image: image,
      mounts: [{tmp_dir, "/workspace"}]
    )

    File.rm_rf!(tmp_dir)

    case result do
      {:ok, _output} ->
        build_and_register_tool(source, test_source, id, opts)
      {:error, reason} ->
        {:error, :gate, reason}
    end
  end

  defp build_and_register_tool(source, test_source, id, opts) do
    description = Keyword.get(opts, :description, "")
    schema      = Keyword.get(opts, :schema, %{})
    constraints = Keyword.get(opts, :constraints, [])

    name = extract_name(source)
    runtime_path = Shem.Lab.Workspace.runtime_path(id)

    tool = %Shem.Tool{
      id: id,
      name: name,
      runtime: {:port, runtime_path},
      source: source,
      test_source: test_source,
      constraints: constraints,
      graduated_at: DateTime.utc_now(),
      metadata: %{
        "language"    => "python",
        "description" => description,
        "schema"      => schema
      }
    }

    :ok = Shem.Lab.Workspace.graduate(tool)
    :ok = Shem.Lab.Registry.register(tool)
    Shem.Adversarial.start_hardening(tool.id)
    {:ok, tool}
  end

  defp extract_name(source) do
    case Regex.run(~r/^def run\(/, source, multiline: true) do
      [_] ->
        source
        |> String.split("\n")
        |> Enum.find(&(&1 =~ ~r/^class \w+|^# name:/))
        |> case do
          nil -> "python_tool"
          line -> String.replace(line, ~r/^(class |# name:)\s*/, "") |> String.trim()
        end
      _ -> "python_tool"
    end
  end

  defp unique_id(source) do
    :crypto.hash(:sha256, source)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end
end
```

**Note on tool naming:** For Phase 43a, the tool name is derived from an optional `# name: MyTool` comment at the top of the Python source or the first class name. The `python_toolsmith` (43b) will establish the convention and always emit this. For now, a `name:` opt on `write_tool` is the fallback.

### 5. `Shem.Lab.PortPool.Supervisor` + `Shem.Lab.PortPool`

**Supervision tree:**

```
Shem.Lab.PortPool.Supervisor  (DynamicSupervisor)
  └── Shem.Lab.PortPool  (GenServer, one per tool, started on first dispatch_lab call)
        ├── Port (python3 runtime_py_path)  -- worker 1
        ├── Port (python3 runtime_py_path)  -- worker 2
        └── ...  (pool_size workers, default 2)
```

Added to `Shem.Application` as a conditional child (like `adversarial_children/0`):

```elixir
defp port_pool_children do
  if Application.get_env(:shem, :start_port_pool, true) do
    [{Shem.Lab.PortPool.Supervisor, []}]
  else
    []
  end
end
```

**`PortPool` GenServer state:**

```elixir
%{
  tool_id: String.t(),
  runtime_path: String.t(),
  pool_size: pos_integer(),
  workers: [:idle | :busy],     # list of Port handles
  queue: :queue.queue()          # blocked callers waiting for a worker
}
```

**`PortPool.call/2`:**

```elixir
@spec call(String.t(), map(), timeout()) :: {:ok, any()} | {:error, String.t()}
def call(tool_id, args, timeout \\ 30_000) do
  pool = ensure_started(tool_id)
  GenServer.call(pool, {:call, args}, timeout)
end
```

`ensure_started/1` uses `DynamicSupervisor.start_child` with `{:via, Registry, ...}` to start the pool idempotently on first use.

Worker Ports opened with:
```elixir
Port.open({:spawn_executable, System.find_executable("python3")},
  [:binary, :use_stdio, :line, args: [runtime_path]])
```

JSON protocol: send `Jason.encode!(args) <> "\n"` to Port, receive one `\n`-terminated line back, `Jason.decode!`.

Error handling: if response contains `{"__error__": "..."}`, return `{:error, reason}`. If Port crashes, supervisor restarts it; the pending call receives `{:error, "worker crashed"}`.

### 6. `Shem.Agent.ToolDispatch` — `dispatch_lab` update

```elixir
defp dispatch_lab(id, args) do
  case Lab.Registry.lookup(id) do
    {:ok, tool} ->
      case tool.runtime do
        {:beam, _mod} ->
          with :ok <- ensure_loaded(tool) do
            try do
              {:ok, inspect(tool.runtime |> elem(1) |> apply(:run, [args]))}
            rescue
              e -> {:error, "runtime error: #{Exception.message(e)}"}
            end
          end

        {:port, _path} ->
          if gate_blocks?(get_trust(tool.id)),
            do: {:error, "tool blocked (trust: low)"},
            else: Lab.PortPool.call(tool.id, args)
      end

    {:error, :not_found} ->
      {:error, "tool not found in registry: #{id}"}
  end
end
```

`ensure_loaded` is unchanged — only called for `{:beam, mod}` path.

### 7. `Shem.MCP.Handlers.InvokeTool` update

```elixir
def call(params) do
  with {:ok, valid} <- Schema.validate(params, @schema),
       {:ok, tool} <- Registry.lookup(valid["id"]) do
    args = Map.get(valid, "args", %{})

    case tool.runtime do
      {:beam, mod} ->
        with :ok <- ensure_loaded(tool) do
          try do
            {:ok, mod.run(args)}
          rescue
            e -> {:error, :runtime, Exception.message(e)}
          end
        end

      {:port, _path} ->
        Lab.PortPool.call(tool.id, args)
    end
  end
end
```

### 8. `write_tool` builtin schema update

```elixir
%{
  name: "write_tool",
  description: "Graduate a new tool into the Lab. Supports language: \"elixir\" (default) or \"python\".",
  schema: %{
    type: "object",
    properties: %{
      "source"      => %{"type" => "string"},
      "test_source" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "schema"      => %{"type" => "object"},
      "language"    => %{"type" => "string"}
    },
    required: ["source", "test_source", "description"]
  }
}
```

`dispatch_builtin("write_tool", args)` extracts `language = args["language"] || "elixir"` and passes `language: language` in opts to `GraduationGate.run/3`.

## Config keys added

```elixir
# config/dev.exs
config :shem,
  executor_image_python: "python:3.12-slim",
  port_pool_size: 2,
  start_port_pool: true

# config/test.exs
config :shem,
  start_port_pool: false
```

## Testing strategy

### Unit tests

- `Workspace`: graduate/read manifest round-trip; legacy `.ex`-only fallback still works; `runtime_path/1` returns correct path
- `Backend.Container`: `mounts:` opt appends `-v` flags to build args
- `GraduationGate`: `language: "python"` routes to `GraduationGate.Python`; `language: "unsupported"` returns `{:error, :unsupported_language, "unsupported"}`; `language: "elixir"` (default) still works as before
- `GraduationGate.Python`: test source failure returns `{:error, :gate, _}`; passing tests register tool with `runtime: {:port, path}`
- `PortPool`: queues calls correctly under concurrency; crashed worker is replaced; `{:error, reason}` returned for Python-side exceptions
- `dispatch_lab`: `{:beam, mod}` takes BEAM path; `{:port, path}` takes PortPool path
- `Tool` struct: `runtime:` is enforce_key; `module:` removed; old structs without `runtime:` handled in `scan_graduated`

### Integration tests

- Graduate a Python tool via `write_tool` API call, invoke it, verify JSON round-trip (requires `python3` on host or container backend)
- Restart `Lab.Registry`, verify graduated tools reload with full metadata from manifest
- Two concurrent agents call the same Python tool; verify no response interleaving

### Regression

- All existing Elixir graduation and dispatch tests pass unchanged
- `build_manifest` surfaces correct descriptions for graduated tools after registry restart

## Out of scope

- `python_toolsmith` preset (Phase 43b)
- Hypothesis/property tests for Python tools — trust seeded at 0.5 (same as non-property Elixir tools)
- BEAM Ports in containers (container for graduation, local for runtime — intentional asymmetry)
- JS, Rust, Go toolsmiths — naming convention reserved, implementation deferred
- Schema validation of Python tool args at call time
- PortPool per-session isolation (global pool per tool is correct for stateless JSON tools)
- Tool marketplace / manifest signing
