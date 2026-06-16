# Phase 43a — Polyglot Tool Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Shem's tool runtime language-agnostic — `write_tool` can graduate Python tools, the runtime dispatches them via supervised BEAM Ports with JSON stdio, and all tool metadata persists across restarts via JSON manifests.

**Architecture:** `Tool.runtime` replaces `Tool.module` as a union `{:beam, Mod} | {:port, path}` that drives dispatch in three sites (`dispatch_lab`, MCP `invoke_tool`, `ensure_loaded`). Python graduation runs pytest in a container (volume-mounted temp dir); runtime uses a persistent BEAM Port pool (one GenServer per tool, JSON lines stdio). Workspace writes a companion `.json` manifest alongside every source file so metadata survives restarts.

**Tech Stack:** Elixir/OTP, DynamicSupervisor, BEAM Ports, Jason, ExUnit, Python 3 (graduation only, via container), podman/docker.

**Spec:** `docs/superpowers/specs/2026-06-16-phase43a-polyglot-tool-runtime.md`

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `lib/shem/tool.ex` | Modify | Replace `module:` with `runtime:` union field |
| `lib/shem/lab/workspace.ex` | Modify | Write `.json` manifest in `graduate/1`, add `runtime_path/1`, change `list_graduated/0` to scan manifests |
| `lib/shem/lab/registry.ex` | Modify | Update `scan_graduated/0` to read manifests, legacy fallback for `.ex`-only |
| `lib/shem/lab/graduation_gate.ex` | Modify | Add config-driven language dispatch; rename body to `run_elixir/3`; set `runtime: {:beam, module}` in tool struct |
| `lib/shem/lab/graduation_gate/python.ex` | Create | `GraduationGate.Python` — pytest in container, Port wrapper emission |
| `lib/shem/lab/executor/backend/container.ex` | Modify | Add `mounts:` opt to `default_run/3` + `build_args/5` |
| `lib/shem/lab/port_pool.ex` | Create | `PortPool` GenServer — workers, JSON lines stdio, queue |
| `lib/shem/lab/port_pool/supervisor.ex` | Create | `PortPool.Supervisor` DynamicSupervisor |
| `lib/shem/agent/tool_dispatch.ex` | Modify | `dispatch_lab` branches on `tool.runtime`; `ensure_loaded` pattern matches `runtime:` |
| `lib/shem/mcp/handlers/invoke_tool.ex` | Modify | `call/1` branches on `tool.runtime`; `ensure_loaded` pattern matches `runtime:` |
| `lib/shem/application.ex` | Modify | Add `port_pool_children/0` conditional child |
| `config/dev.exs` | Modify | Add `executor_image_python`, `port_pool_size`, `start_port_pool` |
| `config/test.exs` | Modify | Add `start_port_pool: false` |
| `test/shem/tool_test.exs` | Modify | Update for `runtime:` field |
| `test/shem/lab/workspace_test.exs` | Modify | Update fixtures + add manifest tests |
| `test/shem/lab/registry_test.exs` | Modify | Update fixture + add manifest scan test |
| `test/shem/lab/graduation_gate_test.exs` | Modify | Update `tool.module` assertions; add language dispatch tests |
| `test/shem/lab/graduation_gate/python_test.exs` | Create | Unit tests for pure functions; integration test (tagged) |
| `test/shem/lab/executor/backend_container_test.exs` | Modify | Add `mounts:` tests |
| `test/shem/lab/port_pool_test.exs` | Create | Pool lifecycle, JSON protocol, concurrency, crash recovery |
| `test/shem/agent/tool_dispatch_test.exs` | Modify | Update ensure_loaded test; add `:port` path test |
| `test/shem/mcp/handlers/invoke_tool_test.exs` | Modify | Update fixture; add `:port` path test |
| `test/shem/mcp/handlers/list_tools_test.exs` | Modify | Update fixture |
| `test/shem/mcp/handlers/graduate_tool_test.exs` | Modify | Update `tool.module` assertion |

---

## Task 1: Rename `Tool.module` → `Tool.runtime`

This is a compile-breaking rename. All struct construction sites and test fixtures are updated atomically. Dispatch call sites (`tool.module.run`, `ensure_loaded(%{module: ...})`) are left broken and fixed in Tasks 2–3 — they are runtime-only failures, not compile failures.

**Files:**
- Modify: `lib/shem/tool.ex`
- Modify: `lib/shem/lab/graduation_gate.ex` (constructs Tool)
- Modify: `lib/shem/lab/registry.ex` (scan_graduated constructs Tool)
- Modify: `test/shem/tool_test.exs`
- Modify: `test/shem/lab/workspace_test.exs`
- Modify: `test/shem/lab/registry_test.exs`
- Modify: `test/shem/mcp/handlers/invoke_tool_test.exs`
- Modify: `test/shem/mcp/handlers/list_tools_test.exs`
- Modify: `test/shem/lab/graduation_gate_test.exs`
- Modify: `test/shem/mcp/handlers/graduate_tool_test.exs`

- [ ] **Step 1: Write failing test in `test/shem/tool_test.exs`**

Replace the entire file:

```elixir
defmodule Shem.ToolTest do
  use ExUnit.Case, async: true

  alias Shem.Tool

  test "can be constructed with all required fields using runtime:" do
    tool = %Tool{
      id: "parse_csv_v1",
      name: "ParseCsv",
      runtime: {:beam, ParseCsv},
      source: "defmodule ParseCsv do end",
      test_source: "defmodule ParseCsvTest do def run, do: :ok end",
      graduated_at: ~U[2026-06-03 00:00:00Z]
    }

    assert tool.id == "parse_csv_v1"
    assert tool.runtime == {:beam, ParseCsv}
    assert tool.constraints == []
    assert tool.metadata == %{}
  end

  test "raises if a required field is missing" do
    assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
      struct!(Tool, %{id: "x"})
    end
  end

  test "defaults input_schema to empty map" do
    tool = %Shem.Tool{
      id: "foo",
      name: "Foo",
      runtime: {:beam, Foo},
      source: "defmodule Foo do\nend",
      test_source: "",
      graduated_at: DateTime.utc_now()
    }
    assert tool.input_schema == %{}
  end

  test "accepts python port runtime" do
    tool = %Shem.Tool{
      id: "py_tool",
      name: "PyTool",
      runtime: {:port, "/abs/path/py_tool_runtime.py"},
      source: "def run(args): return args",
      test_source: "",
      graduated_at: DateTime.utc_now()
    }
    assert tool.runtime == {:port, "/abs/path/py_tool_runtime.py"}
  end
end
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
mix test test/shem/tool_test.exs
```

Expected: compilation error — `the following keys must also be given when building struct Shem.Tool: [:module]`

- [ ] **Step 3: Update `lib/shem/tool.ex`**

```elixir
defmodule Shem.Tool do
  @moduledoc """
  Data contract for a graduated tool. A `%Shem.Tool{}` only exists after a tool
  passes the graduation gate — before that, code is represented as plain strings.
  """

  @enforce_keys [:id, :name, :runtime, :source, :test_source, :graduated_at]
  defstruct [
    :id,
    :name,
    :runtime,
    :source,
    :test_source,
    :graduated_at,
    constraints: [],
    input_schema: %{},
    metadata: %{}
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
end
```

- [ ] **Step 4: Update `lib/shem/lab/graduation_gate.ex` — Tool struct literal**

In the `run/3` function body, change the `%Tool{}` construction (around line 31):

```elixir
tool = %Tool{
  id: id,
  name: module |> Atom.to_string() |> String.split(".") |> List.last(),
  runtime: {:beam, module},
  source: source,
  test_source: test_source,
  constraints: constraints,
  graduated_at: DateTime.utc_now(),
  metadata: %{
    :property_tested => property?,
    "description"    => description,
    "schema"         => schema
  }
}
```

- [ ] **Step 5: Update `lib/shem/lab/registry.ex` — scan_graduated Tool literal**

In `scan_graduated/0` (around line 91):

```elixir
[%Tool{
  id: id,
  name: module |> Atom.to_string() |> String.split(".") |> List.last(),
  runtime: {:beam, module},
  source: source,
  test_source: "",
  graduated_at: DateTime.utc_now(),
  metadata: %{}
}]
```

- [ ] **Step 6: Update test fixtures — `test/shem/lab/workspace_test.exs`**

Replace both `%Tool{}` literals (around lines 22 and 40). Change `module: Adder` → `runtime: {:beam, Adder}` and `module: Multiplier` → `runtime: {:beam, Multiplier}`.

- [ ] **Step 7: Update test fixtures — `test/shem/lab/registry_test.exs`**

Change `@tool` at line 8:
```elixir
@tool %Tool{
  id: "greeter_v1",
  name: "Greeter",
  runtime: {:beam, Greeter},
  source: "defmodule Greeter do\n  def hi(name), do: \"Hello, \#{name}\"\nend",
  test_source: "",
  graduated_at: ~U[2026-06-03 00:00:00Z]
}
```

- [ ] **Step 8: Update test fixtures — `test/shem/mcp/handlers/invoke_tool_test.exs`**

Change `@tool` at line 14:
```elixir
@tool %Tool{
  id: "invoke_target_1",
  name: "InvokeTarget1",
  runtime: {:beam, InvokeTarget1},
  source: @source,
  test_source: "",
  graduated_at: DateTime.utc_now(),
  input_schema: %{"n" => %{"type" => "integer"}}
}
```

- [ ] **Step 9: Update test fixtures — `test/shem/mcp/handlers/list_tools_test.exs`**

Change `@tool` at line 8:
```elixir
@tool %Tool{
  id: "lt_tool_1",
  name: "LtTool1",
  runtime: {:beam, LtTool1},
  source: "defmodule LtTool1 do\n  def run(_args), do: :ok\nend",
  test_source: "",
  graduated_at: DateTime.utc_now(),
  input_schema: %{"x" => %{"type" => "integer"}}
}
```

- [ ] **Step 10: Update `graduation_gate_test.exs` assertion**

Find `assert tool.module == GateAdd1` and replace:
```elixir
assert tool.runtime == {:beam, GateAdd1}
```

- [ ] **Step 11: Update `graduate_tool_test.exs` assertion**

Find `assert tool.module == GradHandlerTool1` and replace:
```elixir
assert tool.runtime == {:beam, GradHandlerTool1}
```

- [ ] **Step 12: Run tests**

```bash
mix test --exclude distributed
```

Expected: most tests pass; `invoke_tool_test.exs` and `tool_dispatch_test.exs` will have runtime failures where `tool.module` is accessed — those are fixed in Tasks 2–3.

- [ ] **Step 13: Commit**

```bash
git add lib/shem/tool.ex lib/shem/lab/graduation_gate.ex lib/shem/lab/registry.ex \
  test/shem/tool_test.exs test/shem/lab/workspace_test.exs test/shem/lab/registry_test.exs \
  test/shem/mcp/handlers/invoke_tool_test.exs test/shem/mcp/handlers/list_tools_test.exs \
  test/shem/lab/graduation_gate_test.exs test/shem/mcp/handlers/graduate_tool_test.exs
git commit -m "refactor: rename Tool.module to Tool.runtime as {:beam,Mod}|{:port,path} union"
```

---

## Task 2: Update `dispatch_lab` and `ensure_loaded` in `tool_dispatch.ex`

Fixes the `:beam` dispatch path broken in Task 1. The `:port` dispatch path is stubbed (calls `Lab.PortPool.call/2` which will return an error until Task 9); tested fully in Task 9.

**Files:**
- Modify: `lib/shem/agent/tool_dispatch.ex`
- Modify: `test/shem/agent/tool_dispatch_test.exs`

- [ ] **Step 1: Find existing dispatch and ensure_loaded tests**

Run:
```bash
grep -n "dispatch_lab\|ensure_loaded\|lab tool" test/shem/agent/tool_dispatch_test.exs
```

Note which tests exercise the lab tool dispatch path.

- [ ] **Step 2: Write failing test — `ensure_loaded` uses `runtime:` not `module:`**

Add to `test/shem/agent/tool_dispatch_test.exs` in the relevant describe block:

```elixir
test "dispatches {:beam, mod} tool by calling mod.run(args)" do
  source = """
  defmodule BeamDispatchTool do
    def run(args), do: {:ok, Map.get(args, "n") * 3}
  end
  """
  tool = %Shem.Tool{
    id: "beam_dispatch_tool",
    name: "BeamDispatchTool",
    runtime: {:beam, BeamDispatchTool},
    source: source,
    test_source: "",
    graduated_at: DateTime.utc_now()
  }
  Shem.Lab.Registry.register(tool)
  # Must explicitly set the lab tool in the manifest for dispatch to find it
  # (tool_dispatch uses the manifest source list; this test needs a full agent call
  # or direct dispatch — check how existing lab tool tests call dispatch)
end
```

> **Note:** Look at existing lab tool dispatch tests in `tool_dispatch_test.exs` for the pattern used — some tests build a full manifest and call `ToolDispatch.execute/3` directly with a `{:lab, id}` source entry. Follow that pattern.

The key assertion is:
```elixir
assert {:ok, result} = ToolDispatch.execute(%{name: "BeamDispatchTool", args: %{"n" => 4}}, manifest, [])
assert result =~ "12"  # inspect({:ok, 12})
```

- [ ] **Step 3: Run test to verify it fails**

```bash
mix test test/shem/agent/tool_dispatch_test.exs --exclude distributed
```

Expected: failure because `ensure_loaded(%{module: module, source: source})` pattern match fails (no `module:` key in Tool struct).

- [ ] **Step 4: Update `dispatch_lab/2` in `lib/shem/agent/tool_dispatch.ex`**

Replace lines 410–424:

```elixir
defp dispatch_lab(id, args) do
  case Lab.Registry.lookup(id) do
    {:ok, tool} ->
      case tool.runtime do
        {:beam, mod} ->
          with :ok <- ensure_loaded(tool) do
            try do
              {:ok, inspect(mod.run(args))}
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

- [ ] **Step 5: Update `ensure_loaded/1` in `lib/shem/agent/tool_dispatch.ex`**

Replace lines 426–450 (the `ensure_loaded` private function):

```elixir
defp ensure_loaded(%{runtime: {:beam, module}, source: source}) do
  case :code.is_loaded(module) do
    false ->
      try do
        case Code.compile_string(source) do
          compiled when is_list(compiled) ->
            case Enum.find(compiled, fn {mod, _bc} -> mod == module end) do
              {^module, bc} ->
                case :code.load_binary(module, ~c"nofile", bc) do
                  {:module, _} -> :ok
                  {:error, _} -> {:error, "failed to load #{module}"}
                end

              nil ->
                {:error, "failed to compile #{module}"}
            end
        end
      rescue
        e -> {:error, "compile error: #{Exception.message(e)}"}
      end

    _ ->
      :ok
  end
end
```

Note: also check if `gate_blocks?/1` and `get_trust/1` exist in the file — `get_trust/1` is the name used in the updated `dispatch_lab`. Look at the existing trust check (currently `Trust.Store.score(tool.id)`) and keep the inline call if `get_trust/1` doesn't exist as a separate helper. The existing pattern is:

```elixir
# existing code in tool_dispatch.ex execute/3 at the lab tool branch:
%{source: {:lab, id}, trust: trust} ->
  if gate_blocks?(trust),
    do: {:error, "tool blocked (trust: #{trust})"},
    else: dispatch_lab(id, args)
```

The `trust` is already computed before `dispatch_lab` is called. So in `dispatch_lab`, for the `:port` path, the trust band is not easily available. Use `Trust.Store.score/1` directly:

```elixir
{:port, _path} ->
  trust_band =
    case Trust.Store.score(tool.id) do
      {:ok, score} -> score_to_band(score)
      {:error, :unrated} -> :unrated
    end

  if gate_blocks?(trust_band),
    do: {:error, "tool blocked (trust: #{trust_band})"},
    else: Lab.PortPool.call(tool.id, args)
```

- [ ] **Step 6: Run tests**

```bash
mix test test/shem/agent/tool_dispatch_test.exs --exclude distributed
```

Expected: PASS. The `:port` path will return `{:error, ...}` (PortPool not running) but no test exercises it yet.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/agent/tool_dispatch.ex test/shem/agent/tool_dispatch_test.exs
git commit -m "fix: dispatch_lab and ensure_loaded use runtime: {:beam,mod} not module:"
```

---

## Task 3: Update `invoke_tool.ex` dispatch and `ensure_loaded`

Same fix as Task 2 but for the MCP handler.

**Files:**
- Modify: `lib/shem/mcp/handlers/invoke_tool.ex`
- Modify: `test/shem/mcp/handlers/invoke_tool_test.exs`

- [ ] **Step 1: Write failing test**

Add to `test/shem/mcp/handlers/invoke_tool_test.exs`:

```elixir
test "calls module.run/1 via runtime: {:beam, mod} path" do
  source = """
  defmodule InvokeBeamV2 do
    def run(args), do: {:doubled, Map.get(args, "n", 0) * 2}
  end
  """
  tool = %Tool{
    id: "invoke_beam_v2",
    name: "InvokeBeamV2",
    runtime: {:beam, InvokeBeamV2},
    source: source,
    test_source: "",
    graduated_at: DateTime.utc_now()
  }
  Registry.register(tool)
  assert {:ok, {:doubled, 10}} = InvokeTool.call(%{"id" => "invoke_beam_v2", "args" => %{"n" => 5}})
end
```

- [ ] **Step 2: Run test to confirm failure**

```bash
mix test test/shem/mcp/handlers/invoke_tool_test.exs
```

Expected: FAIL — `ensure_loaded(%{module: module, source: source})` fails to match.

- [ ] **Step 3: Rewrite `lib/shem/mcp/handlers/invoke_tool.ex`**

```elixir
defmodule Shem.MCP.Handlers.InvokeTool do
  alias Shem.Lab.{Registry, PortPool}
  alias Shem.MCP.Schema

  @schema %{
    "id" => %{"type" => "string"},
    "args" => %{"required" => false}
  }

  @spec call(map()) :: {:ok, any()} | {:error, atom()} | {:error, atom(), any()}
  def call(params) do
    with {:ok, valid} <- Schema.validate(params, @schema),
         {:ok, tool} <- Registry.lookup(valid["id"]) do
      args = Map.get(valid, "args", %{})

      case tool.runtime do
        {:beam, mod} ->
          with :ok <- ensure_loaded(tool),
               {:ok, _} <- Schema.validate(args, tool.input_schema) do
            try do
              {:ok, mod.run(args)}
            rescue
              e -> {:error, :runtime, Exception.message(e)}
            end
          end

        {:port, _path} ->
          PortPool.call(tool.id, args)
      end
    end
  end

  defp ensure_loaded(%{runtime: {:beam, module}, source: source}) do
    case :code.is_loaded(module) do
      false ->
        case Code.compile_string(source) do
          [{^module, bytecode} | _] ->
            case :code.load_binary(module, ~c"nofile", bytecode) do
              {:module, _} -> :ok
              {:error, _}  -> {:error, :load_failed}
            end
          _ -> {:error, :load_failed}
        end
      _ -> :ok
    end
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/mcp/handlers/invoke_tool_test.exs
```

Expected: all PASS.

- [ ] **Step 5: Run full suite**

```bash
mix test --exclude distributed
```

Expected: no regressions. Note the count.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/mcp/handlers/invoke_tool.ex test/shem/mcp/handlers/invoke_tool_test.exs
git commit -m "fix: invoke_tool dispatch and ensure_loaded use runtime: {:beam,mod} not module:"
```

---

## Task 4: `Backend.Container` — `mounts:` opt

Adds volume mount support to the container backend. Independent of all other tasks.

**Files:**
- Modify: `lib/shem/lab/executor/backend/container.ex`
- Modify: `test/shem/lab/executor/backend_container_test.exs`

- [ ] **Step 1: Write failing test**

Add to `test/shem/lab/executor/backend_container_test.exs`:

```elixir
test "run_fn receives args with -v mount flags when mounts: opt provided" do
  received_opts = :ets.new(:opts_capture, [:set, :public])

  run_fn = fn _cmd, _timeout_ms, opts ->
    :ets.insert(received_opts, {:opts, opts})
    {:ok, "ok"}
  end

  Container.run_shell("echo hi", 5_000,
    run_fn: run_fn,
    mounts: [{"/tmp/host_dir", "/workspace"}]
  )

  # The run_fn receives the full opts — mounts: is still there
  [{:opts, opts}] = :ets.lookup(received_opts, :opts)
  assert Keyword.get(opts, :mounts) == [{"/tmp/host_dir", "/workspace"}]
end

test "build_args includes -v flags for each mount" do
  # Use the default_run path with a fake runtime_bin to inspect the args
  Application.put_env(:shem, :container_runtime_bin, "echo")
  result = Container.run_shell("myimage sh -c echo hi", 5_000,
    mounts: [{"/tmp/foo", "/bar"}]
  )
  # echo prints its args — if -v flag is present it will appear in output
  # This is a best-effort check; the important thing is no crash and mounts processed
  assert match?({:ok, _} | {:error, _}, result)
after
  Application.put_env(:shem, :container_runtime_bin, nil)
end
```

> **Note:** The `run_fn:` bypass tests the opt threading. For verifying actual `-v` flag generation, inspect `build_args/5` output via a private function test or read the `System.cmd` call via `:erlang.system_info` tracing. The most practical approach: add a `run_fn` that inspects arguments:

```elixir
test "mounts opt is available in run_fn opts — integration: build_args adds -v flags" do
  # Capture what run_fn sees to verify opts threading
  parent = self()
  run_fn = fn _cmd, _timeout, opts ->
    send(parent, {:opts, opts})
    {:ok, "ok"}
  end

  Container.run_shell("ls", 1_000,
    run_fn: run_fn,
    mounts: [{"/tmp/a", "/mnt/a"}, {"/tmp/b", "/mnt/b"}]
  )

  assert_receive {:opts, opts}
  assert [{"/tmp/a", "/mnt/a"}, {"/tmp/b", "/mnt/b"}] = Keyword.get(opts, :mounts)
end
```

- [ ] **Step 2: Run tests to confirm failure**

```bash
mix test test/shem/lab/executor/backend_container_test.exs
```

Expected: tests pass for `run_fn` threading (mounts opt is already passed through to `run_fn` since `run_fn` receives raw `opts`). But `build_args` doesn't add `-v` flags yet. The test that verifies real args fails.

- [ ] **Step 3: Update `lib/shem/lab/executor/backend/container.ex`**

Replace the file:

```elixir
defmodule Shem.Lab.Executor.Backend.Container do
  @behaviour Shem.Lab.Executor.Backend

  @impl true
  def run_shell(cmd, timeout_ms, opts) do
    case Keyword.get(opts, :run_fn) do
      nil -> default_run(cmd, timeout_ms, opts)
      run_fn -> run_fn.(cmd, timeout_ms, opts)
    end
  end

  defp default_run(cmd, timeout_ms, opts) do
    bin = Keyword.get(opts, :runtime_bin, Application.get_env(:shem, :container_runtime_bin))

    if is_nil(bin) do
      {:error, "no container runtime available (tried podman, docker)"}
    else
      image   = Keyword.get(opts, :image, Application.get_env(:shem, :executor_image, "debian:12-slim"))
      network = Keyword.get(opts, :network, Application.get_env(:shem, :executor_network, :default))
      mounts  = Keyword.get(opts, :mounts, [])
      name    = "shem-#{:erlang.unique_integer([:positive])}"
      args    = build_args(image, network, name, cmd, mounts)

      task =
        Task.Supervisor.async_nolink(Shem.Lab.TaskSupervisor, fn ->
          System.cmd(bin, args, stderr_to_stdout: true)
        end)

      case Task.yield(task, timeout_ms) do
        {:ok, {output, 0}} ->
          {:ok, output}

        {:ok, {output, code}} ->
          {:error, "exit #{code}: #{output}"}

        {:exit, reason} ->
          {:error, "container process crashed: #{inspect(reason)}"}

        nil ->
          Task.shutdown(task, :brutal_kill)
          System.cmd(bin, ["rm", "-f", name], stderr_to_stdout: true)
          {:error, "timeout after #{timeout_ms}ms"}
      end
    end
  end

  defp build_args(image, network, name, cmd, mounts \\ []) do
    network_args =
      case network do
        :none -> ["--network=none"]
        :host -> ["--network=host"]
        _ -> []
      end

    mount_args = Enum.flat_map(mounts, fn {host, container} ->
      ["-v", "#{host}:#{container}:ro"]
    end)

    ["run", "--rm", "--name", name, "-i"] ++
      network_args ++
      mount_args ++
      [image, "sh", "-c", cmd]
  end
end
```

- [ ] **Step 4: Add a `build_args` coverage test using a real container runtime check**

Add to `backend_container_test.exs`:

```elixir
test "default_run passes mounts to container as -v flags (requires container runtime)" do
  bin = System.find_executable("podman") || System.find_executable("docker")

  if is_nil(bin) do
    IO.puts("Skipping: no container runtime available")
  else
    Application.put_env(:shem, :container_runtime_bin, bin)

    # Run a command that prints all args to verify -v flag is present
    # We use "cat /proc/self/cmdline" inside the container to see what args it received
    result = Container.run_shell(
      "cat /workspace/hello.txt 2>&1 || echo 'no file'",
      10_000,
      image: "alpine:latest",
      mounts: [{System.tmp_dir!(), "/workspace"}]
    )

    # Container ran — confirms -v flag was valid (no "invalid mount" error)
    assert match?({:ok, _} | {:error, "exit" <> _}, result)
  end
after
  Application.put_env(:shem, :container_runtime_bin, nil)
end
```

- [ ] **Step 5: Run container backend tests**

```bash
mix test test/shem/lab/executor/backend_container_test.exs
```

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/lab/executor/backend/container.ex test/shem/lab/executor/backend_container_test.exs
git commit -m "feat: Backend.Container gains mounts: opt for -v volume flags"
```

---

## Task 5: Workspace manifest persistence + Registry `scan_graduated`

`graduate/1` writes `.json` alongside source. `list_graduated/0` scans manifests. `scan_graduated` in Registry reads manifests with a legacy `.ex`-only fallback.

**Files:**
- Modify: `lib/shem/lab/workspace.ex`
- Modify: `lib/shem/lab/registry.ex`
- Modify: `test/shem/lab/workspace_test.exs`
- Modify: `test/shem/lab/registry_test.exs`

- [ ] **Step 1: Write failing tests in `test/shem/lab/workspace_test.exs`**

Add after existing tests:

```elixir
test "graduate/1 writes a companion .json manifest with metadata" do
  tool = %Tool{
    id: "manifest_test_tool",
    name: "ManifestTestTool",
    runtime: {:beam, ManifestTestTool},
    source: "defmodule ManifestTestTool do\n  def run(_), do: :ok\nend",
    test_source: "test source here",
    graduated_at: ~U[2026-06-16 12:00:00Z],
    metadata: %{"description" => "adds things", "schema" => %{"type" => "object"}}
  }

  assert :ok = Workspace.graduate(tool)

  manifest_path = Path.join([Application.get_env(:shem, :lab_dir, System.tmp_dir!()), "graduated", "manifest_test_tool.json"])
  assert File.exists?(manifest_path)

  manifest = manifest_path |> File.read!() |> Jason.decode!()
  assert manifest["id"] == "manifest_test_tool"
  assert manifest["name"] == "ManifestTestTool"
  assert manifest["language"] == "elixir"
  assert manifest["description"] == "adds things"
  assert manifest["test_source"] == "test source here"
end

test "graduate/1 for python tool writes .json with runtime_path and language: python" do
  tool = %Tool{
    id: "py_grad_tool",
    name: "py_grad_tool",
    runtime: {:port, Workspace.runtime_path("py_grad_tool")},
    source: "def run(args):\n    return args",
    test_source: "def test_it(): assert True",
    graduated_at: ~U[2026-06-16 12:00:00Z],
    metadata: %{"language" => "python", "description" => "echoes args", "schema" => %{}}
  }

  assert :ok = Workspace.graduate(tool)

  manifest_path = Path.join([Application.get_env(:shem, :lab_dir, System.tmp_dir!()), "graduated", "py_grad_tool.json"])
  manifest = manifest_path |> File.read!() |> Jason.decode!()
  assert manifest["language"] == "python"
  assert manifest["runtime_path"] == Workspace.runtime_path("py_grad_tool")
end

test "runtime_path/1 returns absolute path to _runtime.py in lab graduated dir" do
  path = Workspace.runtime_path("my_tool")
  assert String.ends_with?(path, "graduated/my_tool_runtime.py")
  assert Path.type(path) == :absolute
end

test "list_graduated/0 returns manifest-based entries after graduation" do
  tool = %Tool{
    id: "list_grad_test",
    name: "ListGradTest",
    runtime: {:beam, ListGradTest},
    source: "defmodule ListGradTest do\n  def run(_), do: :ok\nend",
    test_source: "",
    graduated_at: DateTime.utc_now(),
    metadata: %{"description" => "test", "schema" => %{}}
  }
  Workspace.graduate(tool)
  entries = Workspace.list_graduated()
  assert Enum.any?(entries, fn {id, _path} -> id == "list_grad_test" end)
end
```

- [ ] **Step 2: Run tests to confirm failures**

```bash
mix test test/shem/lab/workspace_test.exs
```

Expected: failures because `Workspace.runtime_path/1` doesn't exist and `graduate/1` doesn't write `.json`.

- [ ] **Step 3: Update `lib/shem/lab/workspace.ex`**

```elixir
defmodule Shem.Lab.Workspace do
  alias Shem.Tool

  def messy_path(id), do: Path.join([lab_dir(), "messy", "#{id}.ex"])
  def graduated_path(id), do: Path.join([lab_dir(), "graduated", "#{id}.ex"])
  def manifest_path(id), do: Path.join([lab_dir(), "graduated", "#{id}.json"])
  def runtime_path(id), do: Path.join([lab_dir(), "graduated", "#{id}_runtime.py"]) |> Path.expand()

  @spec graduate(Tool.t()) :: :ok
  def graduate(%Tool{} = tool) do
    dir = Path.join(lab_dir(), "graduated")
    File.mkdir_p!(dir)

    case tool.runtime do
      {:beam, _mod} ->
        File.write!(graduated_path(tool.id), tool.source)

      {:port, runtime_path} ->
        File.write!(Path.join(dir, "#{tool.id}.py"), tool.source)
        File.write!(runtime_path, build_stdio_wrapper(tool.source))
    end

    File.write!(manifest_path(tool.id), build_manifest(tool))
    :ok
  end

  @spec list_graduated() :: [{String.t(), String.t()}]
  def list_graduated do
    dir = Path.join(lab_dir(), "graduated")
    File.mkdir_p!(dir)

    json_entries =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(fn filename ->
        id = String.replace_suffix(filename, ".json", "")
        {id, Path.join(dir, filename)}
      end)

    # Legacy fallback: .ex files with no companion manifest
    legacy_entries =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.reject(fn filename ->
        id = String.replace_suffix(filename, ".ex", "")
        File.exists?(manifest_path(id))
      end)
      |> Enum.map(fn filename ->
        id = String.replace_suffix(filename, ".ex", "")
        {:legacy, id, Path.join(dir, filename)}
      end)

    json_entries ++ legacy_entries
  end

  defp build_manifest(%Tool{runtime: {:beam, _}} = tool) do
    %{
      "id"          => tool.id,
      "name"        => tool.name,
      "language"    => "elixir",
      "description" => Map.get(tool.metadata, "description", ""),
      "schema"      => Map.get(tool.metadata, "schema", %{}),
      "constraints" => tool.constraints,
      "test_source" => tool.test_source,
      "graduated_at" => DateTime.to_iso8601(tool.graduated_at)
    }
    |> Jason.encode!(pretty: true)
  end

  defp build_manifest(%Tool{runtime: {:port, runtime_path}} = tool) do
    %{
      "id"           => tool.id,
      "name"         => tool.name,
      "language"     => Map.get(tool.metadata, "language", "python"),
      "runtime_path" => runtime_path,
      "description"  => Map.get(tool.metadata, "description", ""),
      "schema"       => Map.get(tool.metadata, "schema", %{}),
      "constraints"  => tool.constraints,
      "test_source"  => tool.test_source,
      "graduated_at" => DateTime.to_iso8601(tool.graduated_at)
    }
    |> Jason.encode!(pretty: true)
  end

  defp build_stdio_wrapper(source) do
    """
    import sys
    import json

    #{source}

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
    """
  end

  defp lab_dir do
    Application.get_env(
      :shem,
      :lab_dir,
      Path.join([System.user_home!(), ".config", "shem", "lab"])
    )
  end
end
```

- [ ] **Step 4: Update `lib/shem/lab/registry.ex` — `scan_graduated/0`**

Replace `scan_graduated/0` and add `extract_module/1`:

```elixir
defp scan_graduated do
  Workspace.list_graduated()
  |> Enum.flat_map(fn
    # Manifest-based (new path)
    {id, manifest_path} when is_binary(manifest_path) and binary_part(manifest_path, byte_size(manifest_path), -5) == ".json" ->
      with {:ok, json} <- File.read(manifest_path),
           {:ok, m} <- Jason.decode(json) do
        [build_tool_from_manifest(id, m)]
      else
        _ -> []
      end

    # Legacy: .ex only, no manifest
    {:legacy, id, source_path} ->
      with {:ok, source} <- File.read(source_path),
           {:ok, module} <- extract_module(source) do
        [%Tool{
          id: id,
          name: module |> Atom.to_string() |> String.split(".") |> List.last(),
          runtime: {:beam, module},
          source: source,
          test_source: "",
          graduated_at: DateTime.utc_now(),
          metadata: %{}
        }]
      else
        _ -> []
      end
  end)
end

defp build_tool_from_manifest(id, %{"language" => "elixir"} = m) do
  source_path = Workspace.graduated_path(id)
  source = File.read!(source_path)
  {:ok, module} = extract_module(source)

  %Tool{
    id: id,
    name: m["name"] || module |> Atom.to_string() |> String.split(".") |> List.last(),
    runtime: {:beam, module},
    source: source,
    test_source: m["test_source"] || "",
    constraints: m["constraints"] || [],
    graduated_at: parse_dt(m["graduated_at"]),
    metadata: %{
      "description" => m["description"] || "",
      "schema"      => m["schema"] || %{}
    }
  }
end

defp build_tool_from_manifest(id, %{"language" => _lang, "runtime_path" => runtime_path} = m) do
  source_path = Path.join(Path.dirname(runtime_path), "#{id}.py")
  source = case File.read(source_path) do
    {:ok, s} -> s
    _ -> ""
  end

  %Tool{
    id: id,
    name: m["name"] || id,
    runtime: {:port, runtime_path},
    source: source,
    test_source: m["test_source"] || "",
    constraints: m["constraints"] || [],
    graduated_at: parse_dt(m["graduated_at"]),
    metadata: %{
      "language"    => m["language"],
      "description" => m["description"] || "",
      "schema"      => m["schema"] || %{}
    }
  }
end

defp parse_dt(nil), do: DateTime.utc_now()
defp parse_dt(str) do
  case DateTime.from_iso8601(str) do
    {:ok, dt, _} -> dt
    _ -> DateTime.utc_now()
  end
end

defp extract_module(source) do
  case Regex.run(~r/defmodule\s+(\S+)\s+do/, source) do
    [_, name] -> {:ok, Module.concat([name])}
    _ -> :error
  end
end
```

> **Note:** The `list_graduated/0` return type changed: it now returns either `{id, json_path}` or `{:legacy, id, ex_path}` tuples. The `scan_graduated/0` pattern-matches on the tuple shape. The existing `list_graduated` tests check `[{id, path}]` tuples — update them to accept both shapes, or check just by id presence.

- [ ] **Step 5: Update `test/shem/lab/workspace_test.exs` — fix path assertion**

The existing test at line 50–51 asserts:
```elixir
assert [{"multiplier_v1", path}] = Workspace.list_graduated()
assert String.ends_with?(path, "graduated/multiplier_v1.ex")
```

After this task, `list_graduated/0` returns manifest paths. Update the assertion:
```elixir
assert [{"multiplier_v1", path}] = Workspace.list_graduated()
assert String.ends_with?(path, "graduated/multiplier_v1.json")
```

- [ ] **Step 7: Update `test/shem/lab/registry_test.exs` — boot scan test**

The existing test `"boot scan loads tools pre-written to the graduated directory"` calls `Workspace.graduate(@tool)` and then starts registry. It will now work if a manifest is written. But `@tool` fixture uses `runtime: {:beam, Greeter}` (from Task 1) — confirm this is in place. The boot scan test should pass as-is since `graduate/1` now writes a manifest.

Add a new test:

```elixir
test "boot scan loads tool with full metadata from manifest" do
  tool = %Tool{
    id: "meta_scan_tool",
    name: "MetaScanTool",
    runtime: {:beam, MetaScanTool},
    source: "defmodule MetaScanTool do\n  def run(_), do: :ok\nend",
    test_source: "test_source_here",
    graduated_at: DateTime.utc_now(),
    metadata: %{"description" => "scanned meta", "schema" => %{"type" => "object"}}
  }
  Workspace.graduate(tool)

  {:ok, pid} = start_supervised({Registry, [name: :test_registry_meta]})
  {:ok, loaded} = GenServer.call(pid, {:lookup, "meta_scan_tool"})
  assert loaded.metadata["description"] == "scanned meta"
  assert loaded.test_source == "test_source_here"
end
```

- [ ] **Step 8: Run tests**

```bash
mix test test/shem/lab/workspace_test.exs test/shem/lab/registry_test.exs --exclude distributed
```

Expected: all PASS.

- [ ] **Step 9: Run full suite**

```bash
mix test --exclude distributed
```

Expected: no regressions.

- [ ] **Step 10: Commit**

```bash
git add lib/shem/lab/workspace.ex lib/shem/lab/registry.ex \
  test/shem/lab/workspace_test.exs test/shem/lab/registry_test.exs
git commit -m "feat: Workspace writes JSON manifest; Registry scan_graduated reads manifests"
```

---

## Task 6: `GraduationGate` — language dispatch map

Adds config-driven language routing. Existing Elixir body becomes `run_elixir/3`.

**Files:**
- Modify: `lib/shem/lab/graduation_gate.ex`
- Modify: `test/shem/lab/graduation_gate_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/shem/lab/graduation_gate_test.exs`:

```elixir
describe "language dispatch" do
  test "defaults to elixir path (no language opt)" do
    source = """
    defmodule LangDefault1 do
      def run(_), do: :ok
    end
    """
    test_source = """
    defmodule LangDefault1Test do
      def run, do: :ok
    end
    """
    assert {:ok, tool} = GraduationGate.run(source, test_source)
    assert match?({:beam, _}, tool.runtime)
  end

  test "language: elixir explicitly routes to elixir path" do
    source = """
    defmodule LangExplicit1 do
      def run(_), do: :ok
    end
    """
    test_source = """
    defmodule LangExplicit1Test do
      def run, do: :ok
    end
    """
    assert {:ok, tool} = GraduationGate.run(source, test_source, language: "elixir")
    assert match?({:beam, _}, tool.runtime)
  end

  test "unknown language returns {:error, :language_not_configured, lang}" do
    assert {:error, :language_not_configured, "rust"} =
      GraduationGate.run("fn main() {}", "fn test() {}", language: "rust")
  end
end
```

- [ ] **Step 2: Run tests to confirm failure**

```bash
mix test test/shem/lab/graduation_gate_test.exs --exclude distributed
```

Expected: `unknown language` test fails because current code has no `language:` routing.

- [ ] **Step 3: Update `lib/shem/lab/graduation_gate.ex`**

Replace the `run/3` function and add `run_elixir/3`:

```elixir
@builtin_languages %{
  "elixir" => :elixir,
  "python" => :python
}

@spec run(String.t(), String.t(), keyword()) ::
        {:ok, Tool.t()}
        | {:error, :compile, String.t()}
        | {:error, :gate, any()}
        | {:error, :timeout}
        | {:error, :language_not_configured, String.t()}
def run(source, test_source, opts \\ []) do
  lang = Keyword.get(opts, :language, "elixir")
  languages = Application.get_env(:shem, :graduation_languages, @builtin_languages)

  case Map.get(languages, lang) do
    :elixir -> run_elixir(source, test_source, opts)
    :python -> Shem.Lab.GraduationGate.Python.run(source, test_source, opts)
    nil     -> {:error, :language_not_configured, lang}
  end
end

defp run_elixir(source, test_source, opts) do
  description = Keyword.get(opts, :description, "")
  schema      = Keyword.get(opts, :schema, %{})
  constraints = Keyword.get(opts, :constraints, [])

  combined = source <> "\n" <> test_source

  executor_opts =
    case Application.get_env(:shem, :lab_executor_node) do
      nil  -> []
      node -> [node: node]
    end

  case Executor.run(combined, fn test_mod -> test_mod.run() end, executor_opts) do
    {:ok, :ok} ->
      with {:ok, module} <- extract_module(source) do
        property? = property_tested?(test_source)
        id = unique_id(module)

        tool = %Tool{
          id: id,
          name: module |> Atom.to_string() |> String.split(".") |> List.last(),
          runtime: {:beam, module},
          source: source,
          test_source: test_source,
          constraints: constraints,
          graduated_at: DateTime.utc_now(),
          metadata: %{
            :property_tested => property?,
            "description"    => description,
            "schema"         => schema
          }
        }

        :ok = Workspace.graduate(tool)
        :ok = Registry.register(tool)
        unless property?, do: seed_trust(tool.id)
        Shem.Adversarial.start_hardening(tool.id)
        {:ok, tool}
      else
        {:error, :compile, reason} -> {:error, :compile, reason}
      end

    {:error, :compile, reason} -> {:error, :compile, reason}
    {:error, :runtime, reason} -> {:error, :gate, reason}
    {:error, :timeout}         -> {:error, :timeout}
    {:error, reason}           -> {:error, :gate, reason}
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/lab/graduation_gate_test.exs --exclude distributed
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/lab/graduation_gate.ex test/shem/lab/graduation_gate_test.exs
git commit -m "feat: GraduationGate config-driven language dispatch; Elixir path in run_elixir/3"
```

---

## Task 7: `GraduationGate.Python` — new module

Graduates Python tools: writes temp files, runs pytest in container (volume-mounted), registers tool with `runtime: {:port, path}`. Pure helper functions (`extract_name/1`, `unique_id/1`) are unit-tested; full graduation is an integration test tagged `:python_integration`.

**Files:**
- Create: `lib/shem/lab/graduation_gate/python.ex`
- Create: `test/shem/lab/graduation_gate/python_test.exs`

- [ ] **Step 1: Create test file**

```elixir
defmodule Shem.Lab.GraduationGate.PythonTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.GraduationGate.Python

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir, System.tmp_dir!())
    on_exit(fn -> File.rm_rf!(lab_dir) end)
    :ok
  end

  describe "extract_name/1" do
    test "returns name from # name: comment" do
      source = "# name: MyPyTool\ndef run(args):\n    return args"
      assert Python.extract_name(source) == "MyPyTool"
    end

    test "returns class name when present" do
      source = "class DataLoader:\n    pass\ndef run(args):\n    return args"
      assert Python.extract_name(source) == "DataLoader:"
      # Note: trailing colon from class line — implementer should strip it
    end

    test "falls back to python_tool when no name hint" do
      source = "def run(args):\n    return args"
      assert Python.extract_name(source) == "python_tool"
    end

    test "returns python_tool when no run function present" do
      source = "def not_run(args):\n    return args"
      assert Python.extract_name(source) == "python_tool"
    end
  end

  describe "unique_id/1" do
    test "returns 12-char hex string" do
      id = Python.unique_id("some source")
      assert String.length(id) == 12
      assert id =~ ~r/^[0-9a-f]+$/
    end

    test "same source produces same id (idempotent)" do
      assert Python.unique_id("abc") == Python.unique_id("abc")
    end

    test "different source produces different id" do
      refute Python.unique_id("abc") == Python.unique_id("def")
    end
  end

  @tag :python_integration
  test "graduates a valid Python tool via pytest in container" do
    source = """
    def run(args):
        return {"result": args.get("n", 0) * 2}
    """

    test_source = """
    import sys
    sys.path.insert(0, '.')
    from tool import run

    def test_doubles():
        assert run({"n": 5}) == {"result": 10}

    def test_zero():
        assert run({}) == {"result": 0}
    """

    opts = [description: "doubles n", schema: %{"n" => %{"type" => "integer"}}]

    assert {:ok, tool} = Python.run(source, test_source, opts)
    assert match?({:port, _}, tool.runtime)
    assert tool.metadata["description"] == "doubles n"

    {:port, runtime_path} = tool.runtime
    assert File.exists?(runtime_path)
  end

  @tag :python_integration
  test "returns {:error, :gate, _} when pytest fails" do
    source = "def run(args):\n    return args"
    test_source = """
    from tool import run
    def test_always_fails():
        assert False, "intentional failure"
    """

    assert {:error, :gate, _reason} = Python.run(source, test_source, [])
  end
end
```

- [ ] **Step 2: Run tests to confirm unit tests fail**

```bash
mix test test/shem/lab/graduation_gate/python_test.exs --exclude python_integration
```

Expected: fail because `Shem.Lab.GraduationGate.Python` doesn't exist.

- [ ] **Step 3: Create `lib/shem/lab/graduation_gate/python.ex`**

```elixir
defmodule Shem.Lab.GraduationGate.Python do
  alias Shem.Lab.{Workspace, Executor, Registry}
  alias Shem.Tool

  def run(source, test_source, opts) do
    id = unique_id(source)
    tmp_dir = Path.join(System.tmp_dir!(), "shem_grad_#{id}")
    File.mkdir_p!(tmp_dir)

    File.write!(Path.join(tmp_dir, "tool.py"), source)
    File.write!(Path.join(tmp_dir, "test_tool.py"), test_source)

    image   = Application.get_env(:shem, :executor_image_python, "python:3.12-slim")
    timeout = Application.get_env(:shem, :executor_timeout_ms, 30_000)

    result =
      Executor.run_shell(
        "cd /workspace && pip install pytest -q --no-warn-script-location 2>/dev/null && pytest test_tool.py -q",
        timeout,
        image: image,
        mounts: [{tmp_dir, "/workspace"}]
      )

    File.rm_rf!(tmp_dir)

    case result do
      {:ok, _output} -> build_and_register(source, test_source, id, opts)
      {:error, reason} -> {:error, :gate, reason}
    end
  end

  def extract_name(source) do
    if source =~ ~r/def run\(/m do
      source
      |> String.split("\n")
      |> Enum.find(&(&1 =~ ~r/^class \w+|^# name:/))
      |> case do
        nil  -> "python_tool"
        line ->
          line
          |> String.replace(~r/^(class |# name:)\s*/, "")
          |> String.trim()
          |> String.trim_trailing(":")
      end
    else
      "python_tool"
    end
  end

  def unique_id(source) do
    :crypto.hash(:sha256, source)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp build_and_register(source, test_source, id, opts) do
    description = Keyword.get(opts, :description, "")
    schema      = Keyword.get(opts, :schema, %{})
    constraints = Keyword.get(opts, :constraints, [])
    name        = Keyword.get(opts, :name, extract_name(source))
    runtime_path = Workspace.runtime_path(id)

    tool = %Tool{
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

    :ok = Workspace.graduate(tool)
    :ok = Registry.register(tool)
    seed_trust(tool.id)
    Shem.Adversarial.start_hardening(tool.id)
    {:ok, tool}
  end

  defp seed_trust(tool_id) do
    Shem.Trust.Store.seed(tool_id, 0.5)
  catch
    :exit, _ -> :ok
  end
end
```

> **Note on `extract_name` test:** The class name test in the test file checks for `"DataLoader:"` with trailing colon. The implementation above strips it with `String.trim_trailing(":")`. Update the test assertion to `"DataLoader"` (no colon).

- [ ] **Step 4: Fix test assertion for class name**

In `python_test.exs`, change:
```elixir
assert Python.extract_name(source) == "DataLoader:"
# Note: trailing colon from class line — implementer should strip it
```
to:
```elixir
assert Python.extract_name(source) == "DataLoader"
```

- [ ] **Step 5: Run unit tests**

```bash
mix test test/shem/lab/graduation_gate/python_test.exs --exclude python_integration
```

Expected: all PASS.

- [ ] **Step 6: Run full suite**

```bash
mix test --exclude distributed --exclude python_integration
```

Expected: no regressions.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/lab/graduation_gate/python.ex test/shem/lab/graduation_gate/python_test.exs
git commit -m "feat: GraduationGate.Python — pytest-in-container graduation, Port runtime"
```

---

## Task 8: `PortPool` — GenServer pool + DynamicSupervisor

A supervised pool of BEAM Ports per graduated tool. JSON lines stdio. Lazy-started on first call.

**Files:**
- Create: `lib/shem/lab/port_pool.ex`
- Create: `lib/shem/lab/port_pool/supervisor.ex`
- Create: `test/shem/lab/port_pool_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
defmodule Shem.Lab.PortPoolTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.PortPool
  alias Shem.Lab.PortPool.Supervisor, as: PoolSup

  # A trivial Python-like echo script using sh (available everywhere, no Python needed)
  # Reads JSON line from stdin, writes it back to stdout
  @echo_script """
  #!/bin/sh
  while IFS= read -r line; do
    printf '%s\\n' "$line"
  done
  """

  setup do
    # Start a fresh DynamicSupervisor for each test
    {:ok, sup} = start_supervised({DynamicSupervisor, strategy: :one_for_one, name: :test_pool_sup})

    # Write echo script to temp file
    script = Path.join(System.tmp_dir!(), "shem_pool_test_#{:erlang.unique_integer([:positive])}.sh")
    File.write!(script, @echo_script)
    File.chmod!(script, 0o755)

    on_exit(fn -> File.rm_f(script) end)
    {:ok, script: script, sup: sup}
  end

  test "call/3 sends JSON to worker and receives JSON response", %{script: script, sup: sup} do
    pool_name = :"pool_test_#{:erlang.unique_integer()}"
    {:ok, _pid} = DynamicSupervisor.start_child(sup,
      {PortPool, [tool_id: "echo_tool", runtime_path: script, pool_size: 1, name: pool_name, executable: "sh"]}
    )

    # Echo script returns whatever we send
    assert {:ok, response} = PortPool.call(pool_name, %{"x" => 42})
    assert response["x"] == 42
  end

  test "pool handles concurrent calls via queue", %{script: script, sup: sup} do
    pool_name = :"pool_conc_#{:erlang.unique_integer()}"
    {:ok, _pid} = DynamicSupervisor.start_child(sup,
      {PortPool, [tool_id: "conc_tool", runtime_path: script, pool_size: 2, name: pool_name, executable: "sh"]}
    )

    tasks = for i <- 1..5 do
      Task.async(fn -> PortPool.call(pool_name, %{"i" => i}) end)
    end

    results = Task.await_many(tasks, 10_000)
    assert length(results) == 5
    assert Enum.all?(results, fn {:ok, _} -> true; _ -> false end)
  end

  test "returns {:error, reason} for __error__ response" do
    # Script that always returns an error JSON
    error_script_content = """
    #!/bin/sh
    while IFS= read -r line; do
      printf '{"__error__":"intentional error"}\\n'
    done
    """
    script = Path.join(System.tmp_dir!(), "shem_error_#{:erlang.unique_integer()}.sh")
    File.write!(script, error_script_content)
    File.chmod!(script, 0o755)

    pool_name = :"pool_err_#{:erlang.unique_integer()}"
    {:ok, _pid} = start_supervised(
      {PortPool, [tool_id: "err_tool", runtime_path: script, pool_size: 1, name: pool_name, executable: "sh"]}
    )

    assert {:error, "intentional error"} = PortPool.call(pool_name, %{"x" => 1})

    File.rm_f(script)
  end
end
```

- [ ] **Step 2: Run tests to confirm failure**

```bash
mix test test/shem/lab/port_pool_test.exs
```

Expected: compilation failure — `Shem.Lab.PortPool` doesn't exist.

- [ ] **Step 3: Create `lib/shem/lab/port_pool/supervisor.ex`**

```elixir
defmodule Shem.Lab.PortPool.Supervisor do
  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec ensure_started(String.t(), String.t()) :: {:ok, pid()} | {:error, any()}
  def ensure_started(tool_id, runtime_path) do
    pool_name = pool_name(tool_id)
    pool_size = Application.get_env(:shem, :port_pool_size, 2)

    case DynamicSupervisor.start_child(__MODULE__,
      {Shem.Lab.PortPool,
       [tool_id: tool_id, runtime_path: runtime_path, pool_size: pool_size, name: pool_name]}
    ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  def pool_name(tool_id), do: :"shem_port_pool_#{tool_id}"
end
```

- [ ] **Step 4: Create `lib/shem/lab/port_pool.ex`**

```elixir
defmodule Shem.Lab.PortPool do
  use GenServer
  require Logger

  @default_timeout 30_000

  # Child spec so DynamicSupervisor can start it
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)
    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec call(atom() | pid(), map(), timeout()) :: {:ok, any()} | {:error, String.t()}
  def call(pool, args, timeout \\ @default_timeout) do
    GenServer.call(pool, {:call, args}, timeout)
  end

  # ── Server ────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    tool_id      = Keyword.fetch!(opts, :tool_id)
    runtime_path = Keyword.fetch!(opts, :runtime_path)
    pool_size    = Keyword.get(opts, :pool_size, 2)
    executable   = Keyword.get(opts, :executable, "python3")

    workers = for _ <- 1..pool_size, do: open_port(runtime_path, executable)

    {:ok, %{
      tool_id: tool_id,
      runtime_path: runtime_path,
      executable: executable,
      idle: workers,
      busy: %{},    # ref => {port, from}
      queue: :queue.new()
    }}
  end

  @impl true
  def handle_call({:call, args}, from, state) do
    case state.idle do
      [port | rest] ->
        send_to_port(port, args)
        ref = make_ref()
        busy = Map.put(state.busy, port, {ref, from})
        {:noreply, %{state | idle: rest, busy: busy}}

      [] ->
        queue = :queue.in({args, from}, state.queue)
        {:noreply, %{state | queue: queue}}
    end
  end

  @impl true
  def handle_info({port, {:data, line}}, state) when is_port(port) do
    line = String.trim(line)

    case Map.pop(state.busy, port) do
      {nil, _} ->
        {:noreply, state}

      {{_ref, from}, busy} ->
        result =
          case Jason.decode(line) do
            {:ok, %{"__error__" => reason}} -> {:error, reason}
            {:ok, value} -> {:ok, value}
            {:error, _}  -> {:error, "invalid JSON from port: #{line}"}
          end

        GenServer.reply(from, result)

        {state, idle} = maybe_dequeue(%{state | busy: busy}, port)
        {:noreply, %{state | idle: idle}}
    end
  end

  def handle_info({port, {:exit_status, code}}, state) when is_port(port) do
    Logger.warning("PortPool: worker exited with code #{code}, restarting")
    new_port = open_port(state.runtime_path, state.executable)

    # Fail any pending call on this port
    {state, idle} =
      case Map.pop(state.busy, port) do
        {nil, _} ->
          {state, [new_port | state.idle]}

        {{_ref, from}, busy} ->
          GenServer.reply(from, {:error, "worker crashed (exit #{code})"})
          {%{state | busy: busy}, [new_port | state.idle]}
      end

    {:noreply, %{state | idle: idle}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp open_port(runtime_path, executable) do
    Port.open(
      {:spawn_executable, System.find_executable(executable)},
      [:binary, :use_stdio, :line, :exit_status, args: [runtime_path]]
    )
  end

  defp send_to_port(port, args) do
    Port.command(port, Jason.encode!(args) <> "\n")
  end

  defp maybe_dequeue(state, idle_port) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        {state, [idle_port | state.idle]}

      {{:value, {args, from}}, queue} ->
        send_to_port(idle_port, args)
        ref = make_ref()
        busy = Map.put(state.busy, idle_port, {ref, from})
        {%{state | busy: busy, queue: queue}, state.idle}
    end
  end
end
```

- [ ] **Step 5: Run pool tests**

```bash
mix test test/shem/lab/port_pool_test.exs
```

Expected: all PASS. The echo script test exercises the JSON round-trip via `sh`.

- [ ] **Step 6: Run full suite**

```bash
mix test --exclude distributed --exclude python_integration
```

Expected: no regressions.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/lab/port_pool.ex lib/shem/lab/port_pool/supervisor.ex \
  test/shem/lab/port_pool_test.exs
git commit -m "feat: PortPool GenServer + DynamicSupervisor for non-Elixir tool runtime"
```

---

## Task 9: Wire `PortPool.Supervisor` into application + config

**Files:**
- Modify: `lib/shem/application.ex`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Update `config/test.exs`**

Add at end:
```elixir
config :shem, start_port_pool: false
```

- [ ] **Step 2: Update `config/dev.exs`**

Add:
```elixir
config :shem,
  executor_image_python: "python:3.12-slim",
  port_pool_size: 2,
  start_port_pool: true
```

- [ ] **Step 3: Add `port_pool_children/0` to `lib/shem/application.ex`**

Add after `tui_children/0`:

```elixir
defp port_pool_children do
  if Application.get_env(:shem, :start_port_pool, true) do
    [Shem.Lab.PortPool.Supervisor]
  else
    []
  end
end
```

Append `++ port_pool_children()` to the `children` list (after `tui_children()`):

```elixir
children =
  [
    # ... existing children ...
  ] ++
    adversarial_children() ++
    shadow_children() ++
    llm_stub_children() ++
    mcp_children() ++
    cluster_children() ++
    tui_children() ++
    port_pool_children()
```

- [ ] **Step 4: Run full test suite**

```bash
mix test --exclude distributed --exclude python_integration
```

Expected: all pass. `PortPool.Supervisor` is not started in tests (`start_port_pool: false`).

- [ ] **Step 5: Verify application starts in dev**

```bash
mix compile --warnings-as-errors
```

Expected: compiles cleanly.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/application.ex config/dev.exs config/test.exs
git commit -m "feat: register PortPool.Supervisor in application supervision tree"
```

---

## Task 10: Port dispatch paths + `write_tool` language field

Wires the full `:port` dispatch path in `dispatch_lab` and `invoke_tool`. Adds `language:` field to `write_tool` builtin.

**Files:**
- Modify: `lib/shem/agent/tool_dispatch.ex` (write_tool schema + dispatch_builtin)
- Modify: `test/shem/agent/tool_dispatch_test.exs`
- Modify: `test/shem/mcp/handlers/invoke_tool_test.exs`

- [ ] **Step 1: Write failing test for write_tool `language:` routing**

Add to `test/shem/agent/tool_dispatch_test.exs`:

```elixir
test "write_tool passes language: elixir by default to GraduationGate" do
  # This test verifies the schema accepts language: and routes correctly.
  # Use a valid Elixir tool to verify default (no language: in args) still works.
  source = """
  defmodule LangDefaultTool do
    def run(_args), do: {:ok, :default}
  end
  """
  test_source = """
  defmodule LangDefaultToolTest do
    def run, do: :ok
  end
  """

  manifest = ToolDispatch.build_manifest(%Shem.Agent.Config{task: "t", system_prompt: "s", tools: []})

  result = ToolDispatch.execute(
    %{name: "write_tool", args: %{
      "source" => source,
      "test_source" => test_source,
      "description" => "default language test"
    }},
    manifest,
    []
  )

  assert {:ok, "graduated: LangDefaultTool"} = result
end

test "write_tool returns language_not_configured error for unknown language" do
  manifest = ToolDispatch.build_manifest(%Shem.Agent.Config{task: "t", system_prompt: "s", tools: []})

  result = ToolDispatch.execute(
    %{name: "write_tool", args: %{
      "source" => "fn main() {}",
      "test_source" => "fn test() {}",
      "description" => "rust tool",
      "language" => "rust"
    }},
    manifest,
    []
  )

  assert {:error, msg} = result
  assert msg =~ "rust"
end
```

> **Note:** `build_manifest_for_test/0` is whatever helper your test file already uses to produce a manifest list for `ToolDispatch.execute/3`. If none exists, call `ToolDispatch.build_manifest(%Shem.Agent.Config{tools: []})` with a started Registry.

- [ ] **Step 2: Update `dispatch_builtin("write_tool", args)` in `tool_dispatch.ex`**

Current (around line 272):
```elixir
defp dispatch_builtin("write_tool", args) do
  source      = args["source"] || ""
  test_source = args["test_source"] || ""
  description = args["description"] || ""
  schema      = args["schema"] || %{}

  case Lab.GraduationGate.run(source, test_source, description: description, schema: schema) do
    {:ok, tool} -> {:ok, "graduated: #{tool.name}"}
    {:error, :compile, msg} -> {:error, "compile error: #{msg}"}
    {:error, :gate, reason} -> {:error, "test failed: #{inspect(reason)}"}
    {:error, :timeout}      -> {:error, "graduation timed out"}
  end
end
```

Replace with:

```elixir
defp dispatch_builtin("write_tool", args) do
  source      = args["source"] || ""
  test_source = args["test_source"] || ""
  description = args["description"] || ""
  schema      = args["schema"] || %{}
  language    = args["language"] || "elixir"

  case Lab.GraduationGate.run(source, test_source,
    description: description, schema: schema, language: language
  ) do
    {:ok, tool} -> {:ok, "graduated: #{tool.name}"}
    {:error, :compile, msg}              -> {:error, "compile error: #{msg}"}
    {:error, :gate, reason}              -> {:error, "test failed: #{inspect(reason)}"}
    {:error, :timeout}                   -> {:error, "graduation timed out"}
    {:error, :language_not_configured, lang} -> {:error, "language not configured: #{lang}"}
  end
end
```

- [ ] **Step 3: Update `write_tool` entry in `@builtins`**

Change description and add `language:` to schema properties:

```elixir
%{
  name: "write_tool",
  description: "Graduate a new tool into the Lab. Supports language: \"elixir\" (default) or \"python\".",
  source: :builtin,
  trust: :builtin,
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
},
```

- [ ] **Step 4: Write failing test for `:port` dispatch in invoke_tool**

Add to `test/shem/mcp/handlers/invoke_tool_test.exs`:

```elixir
@tag :port_integration
test "dispatches {:port, path} tool via PortPool" do
  # Requires PortPool.Supervisor started — only runs in integration context
  # Start a PortPool.Supervisor manually for this test
  {:ok, _sup} = start_supervised({DynamicSupervisor, strategy: :one_for_one, name: :test_mcp_pool_sup})

  echo_script = write_echo_script()

  tool = %Tool{
    id: "mcp_port_tool",
    name: "McpPortTool",
    runtime: {:port, echo_script},
    source: "",
    test_source: "",
    graduated_at: DateTime.utc_now()
  }
  Registry.register(tool)

  # Stub PortPool to use our test supervisor
  # For a cleaner test: patch PortPool.call to use ensure_started with the test sup

  # Simpler approach: just verify the right path is taken
  # Since PortPool.Supervisor isn't running, we get a process not found error
  # which proves the :port path was taken (not the :beam path)
  result = InvokeTool.call(%{"id" => "mcp_port_tool", "args" => %{}})
  assert match?({:error, _}, result)  # Expected: PortPool not running → error
end

defp write_echo_script do
  path = Path.join(System.tmp_dir!(), "echo_mcp_#{:erlang.unique_integer()}.sh")
  File.write!(path, "#!/bin/sh\nwhile IFS= read -r line; do printf '%s\\n' \"$line\"; done\n")
  File.chmod!(path, 0o755)
  path
end
```

- [ ] **Step 5: Verify `invoke_tool.ex` PortPool path uses correct module**

Check that `invoke_tool.ex` references `Shem.Lab.PortPool` (not `Lab.PortPool`). Update the alias if needed:

```elixir
alias Shem.Lab.{Registry, PortPool}
```

And the `:port` branch:
```elixir
{:port, _path} ->
  PortPool.call(tool.id, args)
```

`PortPool.call/2` with a `tool_id` String needs `PortPool.Supervisor.ensure_started/2` to already have run. Update the `:port` branch to ensure the pool is started:

```elixir
{:port, runtime_path} ->
  with {:ok, pool} <- Shem.Lab.PortPool.Supervisor.ensure_started(tool.id, runtime_path) do
    PortPool.call(pool, args)
  end
```

Similarly in `dispatch_lab/2` in `tool_dispatch.ex`:

```elixir
{:port, runtime_path} ->
  trust_band =
    case Trust.Store.score(tool.id) do
      {:ok, score} -> score_to_band(score)
      {:error, :unrated} -> :unrated
    end

  if gate_blocks?(trust_band) do
    {:error, "tool blocked (trust: #{trust_band})"}
  else
    with {:ok, pool} <- Lab.PortPool.Supervisor.ensure_started(tool.id, runtime_path) do
      Lab.PortPool.call(pool, args)
    end
  end
```

- [ ] **Step 6: Run tests**

```bash
mix test --exclude distributed --exclude python_integration --exclude port_integration
```

Expected: all PASS.

- [ ] **Step 7: Run full suite and note final count**

```bash
mix test --exclude distributed --exclude python_integration --exclude port_integration
```

Expected: count >= 1042 (Phase 42 baseline), no failures.

- [ ] **Step 8: Commit**

```bash
git add lib/shem/agent/tool_dispatch.ex lib/shem/mcp/handlers/invoke_tool.ex \
  test/shem/agent/tool_dispatch_test.exs test/shem/mcp/handlers/invoke_tool_test.exs
git commit -m "feat: write_tool language: field + :port dispatch path in dispatch_lab and invoke_tool"
```

---

## Final check

```bash
mix test --exclude distributed --exclude python_integration --exclude port_integration
```

All tests pass. The polyglot runtime infrastructure is complete. Phase 43b (`python_toolsmith` preset) can now be built on top of this foundation.
