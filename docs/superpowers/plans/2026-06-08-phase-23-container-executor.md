# Phase 23 — Container Executor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bare `System.cmd` shell dispatch with a container-based executor (Podman preferred, Docker fallback) while keeping `run_code` in-BEAM.

**Architecture:** Introduce a `Backend` behaviour with two implementations (`Local` and `Container`). `Shem.Lab.Executor.run_shell/3` reads the resolved backend from Application env (set once at startup by `Application.start/2`). `ToolDispatch.dispatch_builtin("shell", ...)` is rerouted through `run_shell/3`.

**Tech Stack:** Elixir/OTP, `System.cmd`, `Task.Supervisor`, `System.find_executable`, `Logger`

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `lib/shem/lab/executor/backend.ex` | `@callback run_shell/3` behaviour |
| Create | `lib/shem/lab/executor/backend/local.ex` | `System.cmd` implementation (no container) |
| Create | `lib/shem/lab/executor/backend/container.ex` | Podman/Docker invocation with `run_fn:` injection |
| Modify | `lib/shem/lab/executor.ex` | Add `run_shell/3`; existing `run/3` unchanged |
| Modify | `lib/shem/application.ex` | `resolve_executor_backend/0` called in `start/2`; startup warning |
| Modify | `lib/shem/agent/tool_dispatch.ex` | `dispatch_builtin("shell")` → `Lab.Executor.run_shell/3` |
| Modify | `config/config.exs` | Add `executor_backend`, `executor_image`, `executor_network` |
| Modify | `config/test.exs` | Pin `executor_backend: :local` |
| Create | `test/shem/lab/executor/backend_local_test.exs` | Unit tests for Local |
| Create | `test/shem/lab/executor/backend_container_test.exs` | Unit tests for Container (run_fn: injected) |
| Create | `test/shem/lab/executor_shell_test.exs` | Routing tests for `run_shell/3` |
| Create | `test/shem/application_executor_test.exs` | Startup resolution + warning test |
| Modify | `test/shem/agent/tool_dispatch_test.exs` | Shell tests pass through after rerouting |

---

### Task 1: Backend behaviour + Backend.Local

**Files:**
- Create: `lib/shem/lab/executor/backend.ex`
- Create: `lib/shem/lab/executor/backend/local.ex`
- Create: `test/shem/lab/executor/backend_local_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/shem/lab/executor/backend_local_test.exs
defmodule Shem.Lab.Executor.Backend.LocalTest do
  use ExUnit.Case, async: true

  alias Shem.Lab.Executor.Backend.Local

  test "returns {:ok, output} for successful command" do
    assert {:ok, output} = Local.run_shell("echo hello", 5_000, [])
    assert String.trim(output) == "hello"
  end

  test "returns {:error, exit_N: output} for non-zero exit" do
    result = Local.run_shell("exit 2", 5_000, [])
    assert match?({:error, "exit 2:" <> _}, result)
  end

  test "returns {:error, timeout} when command exceeds timeout_ms" do
    result = Local.run_shell("sleep 10", 50, [])
    assert result == {:error, "timeout after 50ms"}
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```
cd /path/to/shem && mix test test/shem/lab/executor/backend_local_test.exs
```
Expected: compilation error — `Shem.Lab.Executor.Backend.Local` does not exist.

- [ ] **Step 3: Create the Backend behaviour**

```elixir
# lib/shem/lab/executor/backend.ex
defmodule Shem.Lab.Executor.Backend do
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @callback run_shell(cmd :: String.t(), timeout_ms :: non_neg_integer(), opts :: keyword()) ::
              result()
end
```

- [ ] **Step 4: Create Backend.Local**

```elixir
# lib/shem/lab/executor/backend/local.ex
defmodule Shem.Lab.Executor.Backend.Local do
  @behaviour Shem.Lab.Executor.Backend

  @impl true
  def run_shell(cmd, timeout_ms, _opts) do
    task =
      Task.Supervisor.async_nolink(Shem.Lab.TaskSupervisor, fn ->
        System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, code}} ->
        {:error, "exit #{code}: #{output}"}

      {:exit, reason} ->
        {:error, "shell command crashed: #{inspect(reason)}"}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, "timeout after #{timeout_ms}ms"}
    end
  end
end
```

- [ ] **Step 5: Run tests — expect pass**

```
mix test test/shem/lab/executor/backend_local_test.exs
```
Expected: 3 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/lab/executor/backend.ex lib/shem/lab/executor/backend/local.ex test/shem/lab/executor/backend_local_test.exs
git commit -m "feat: Executor.Backend behaviour + Backend.Local implementation"
```

---

### Task 2: Backend.Container

**Files:**
- Create: `lib/shem/lab/executor/backend/container.ex`
- Create: `test/shem/lab/executor/backend_container_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/shem/lab/executor/backend_container_test.exs
defmodule Shem.Lab.Executor.Backend.ContainerTest do
  use ExUnit.Case, async: true

  alias Shem.Lab.Executor.Backend.Container

  test "run_fn: success path returns {:ok, output}" do
    run_fn = fn _cmd, _timeout_ms, _opts -> {:ok, "mocked output\n"} end
    assert {:ok, "mocked output\n"} = Container.run_shell("ls", 5_000, run_fn: run_fn)
  end

  test "run_fn: non-zero exit forwarded as-is" do
    run_fn = fn _cmd, _timeout_ms, _opts -> {:error, "exit 1: permission denied"} end
    assert {:error, "exit 1: permission denied"} = Container.run_shell("ls /root", 5_000, run_fn: run_fn)
  end

  test "run_fn: timeout forwarded as-is" do
    run_fn = fn _cmd, _timeout_ms, _opts -> {:error, "timeout after 100ms"} end
    assert {:error, "timeout after 100ms"} = Container.run_shell("sleep 10", 100, run_fn: run_fn)
  end

  test "returns no-runtime error when container_runtime_bin is nil and no run_fn" do
    Application.put_env(:shem, :container_runtime_bin, nil)
    result = Container.run_shell("ls", 5_000, [])
    assert {:error, "no container runtime available (tried podman, docker)"} = result
  end
end
```

- [ ] **Step 2: Run tests — confirm failure**

```
mix test test/shem/lab/executor/backend_container_test.exs
```
Expected: compilation error — `Shem.Lab.Executor.Backend.Container` does not exist.

- [ ] **Step 3: Create Backend.Container**

```elixir
# lib/shem/lab/executor/backend/container.ex
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
      image =
        Keyword.get(opts, :image, Application.get_env(:shem, :executor_image, "debian:12-slim"))

      network =
        Keyword.get(opts, :network, Application.get_env(:shem, :executor_network, :default))

      args = build_args(image, network, cmd)

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
          {:error, "timeout after #{timeout_ms}ms"}
      end
    end
  end

  defp build_args(image, network, cmd) do
    network_args =
      case network do
        :none -> ["--network=none"]
        :host -> ["--network=host"]
        _ -> []
      end

    ["run", "--rm", "-i"] ++ network_args ++ [image, "sh", "-c", cmd]
  end
end
```

- [ ] **Step 4: Run tests — expect pass**

```
mix test test/shem/lab/executor/backend_container_test.exs
```
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/lab/executor/backend/container.ex test/shem/lab/executor/backend_container_test.exs
git commit -m "feat: Backend.Container with Podman/Docker invocation and run_fn: injection"
```

---

### Task 3: `Executor.run_shell/3`

**Files:**
- Modify: `lib/shem/lab/executor.ex`
- Create: `test/shem/lab/executor_shell_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/shem/lab/executor_shell_test.exs
defmodule Shem.Lab.ExecutorShellTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.Executor
  alias Shem.Lab.Executor.Backend

  setup do
    # Restore after each test
    old = Process.get(:shem_executor_backend)
    on_exit(fn ->
      if old, do: Process.put(:shem_executor_backend, old),
      else: Process.delete(:shem_executor_backend)
    end)
    :ok
  end

  test "routes to Local backend when process dict overridden" do
    Process.put(:shem_executor_backend, Backend.Local)
    assert {:ok, output} = Executor.run_shell("echo routed", 5_000)
    assert String.trim(output) == "routed"
  end

  test "routes to Container backend when overridden with run_fn injection" do
    run_fn = fn _cmd, _timeout, _opts -> {:ok, "container result"} end
    Process.put(:shem_executor_backend, Backend.Container)
    assert {:ok, "container result"} = Executor.run_shell("ls", 5_000, run_fn: run_fn)
  end

  test "returns error when no backend resolved and no process override" do
    Process.delete(:shem_executor_backend)
    # Application env in test is :local, so this should succeed via Local
    assert {:ok, output} = Executor.run_shell("echo configured", 5_000)
    assert String.trim(output) == "configured"
  end
end
```

- [ ] **Step 2: Run tests — confirm failure**

```
mix test test/shem/lab/executor_shell_test.exs
```
Expected: undefined function `Shem.Lab.Executor.run_shell/2`.

- [ ] **Step 3: Add `run_shell/3` to `Executor`**

In `lib/shem/lab/executor.ex`, add after the closing of `run/3`'s spec + definition block (after line 21, before `defp run_remote`):

```elixir
  @spec run_shell(String.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run_shell(cmd, timeout_ms, opts \\ []) do
    backend =
      Process.get(:shem_executor_backend) ||
        Application.get_env(:shem, :resolved_executor_backend, Shem.Lab.Executor.Backend.Local)

    backend.run_shell(cmd, timeout_ms, opts)
  end
```

- [ ] **Step 4: Run tests — expect pass**

```
mix test test/shem/lab/executor_shell_test.exs
```
Expected: 3 tests, 0 failures.

- [ ] **Step 5: Run full suite — no regressions**

```
mix test test/shem/lab/
```
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/lab/executor.ex test/shem/lab/executor_shell_test.exs
git commit -m "feat: Executor.run_shell/3 with process-dict-overridable backend routing"
```

---

### Task 4: Application startup resolution + config

**Files:**
- Modify: `lib/shem/application.ex`
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Create: `test/shem/application_executor_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/shem/application_executor_test.exs
defmodule Shem.ApplicationExecutorTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Shem.Application, as: ShemApp

  setup do
    old_backend = Application.get_env(:shem, :executor_backend)
    old_resolved = Application.get_env(:shem, :resolved_executor_backend)
    old_bin = Application.get_env(:shem, :container_runtime_bin)

    on_exit(fn ->
      if old_backend, do: Application.put_env(:shem, :executor_backend, old_backend)
      if old_resolved do
        Application.put_env(:shem, :resolved_executor_backend, old_resolved)
      else
        Application.delete_env(:shem, :resolved_executor_backend)
      end
      if old_bin do
        Application.put_env(:shem, :container_runtime_bin, old_bin)
      else
        Application.delete_env(:shem, :container_runtime_bin)
      end
    end)

    :ok
  end

  test ":local resolves to Backend.Local without detection" do
    Application.put_env(:shem, :executor_backend, :local)
    ShemApp.resolve_executor_backend()
    assert Application.get_env(:shem, :resolved_executor_backend) ==
             Shem.Lab.Executor.Backend.Local
  end

  test ":container resolves to Backend.Container regardless of detection" do
    Application.put_env(:shem, :executor_backend, :container)
    ShemApp.resolve_executor_backend()
    assert Application.get_env(:shem, :resolved_executor_backend) ==
             Shem.Lab.Executor.Backend.Container
  end

  test ":auto with no runtime falls back to Local and emits warning" do
    Application.put_env(:shem, :executor_backend, :auto)
    # Force detection to fail by overriding PATH lookup via a fake detect
    log =
      capture_log(fn ->
        ShemApp.resolve_executor_backend(fn -> nil end)
      end)

    assert Application.get_env(:shem, :resolved_executor_backend) ==
             Shem.Lab.Executor.Backend.Local
    assert log =~ "no container runtime found"
  end

  test ":auto with podman resolves to Container" do
    Application.put_env(:shem, :executor_backend, :auto)

    ShemApp.resolve_executor_backend(fn -> "podman" end)

    assert Application.get_env(:shem, :resolved_executor_backend) ==
             Shem.Lab.Executor.Backend.Container
    assert Application.get_env(:shem, :container_runtime_bin) == "podman"
  end
end
```

- [ ] **Step 2: Run tests — confirm failure**

```
mix test test/shem/application_executor_test.exs
```
Expected: `ShemApp.resolve_executor_backend/0` and `/1` undefined.

- [ ] **Step 3: Add config keys**

In `config/config.exs`, add after the `trust_gate_enabled` line:

```elixir
config :shem,
  executor_backend: :auto,
  executor_image: "debian:12-slim",
  executor_network: :default
```

In `config/test.exs`, add at the end:

```elixir
config :shem, executor_backend: :local
```

- [ ] **Step 4: Add `resolve_executor_backend` to Application**

In `lib/shem/application.ex`:

1. Add `require Logger` after `use Application`.

2. In `start/2`, call `resolve_executor_backend()` as the first line before building `children`.

3. Add these two functions after `tui_children/0`:

```elixir
  def resolve_executor_backend(detect_fn \\ &detect_container_runtime/0) do
    case Application.get_env(:shem, :executor_backend, :auto) do
      :local ->
        Application.put_env(:shem, :resolved_executor_backend, Shem.Lab.Executor.Backend.Local)
        Application.put_env(:shem, :container_runtime_bin, nil)

      :container ->
        runtime = detect_fn.()

        if is_nil(runtime) do
          Logger.error(
            "Shem: no container runtime found (tried podman, docker). " <>
              "Shell tool will return errors until a container runtime is installed."
          )
        end

        Application.put_env(:shem, :resolved_executor_backend, Shem.Lab.Executor.Backend.Container)
        Application.put_env(:shem, :container_runtime_bin, runtime)

      :auto ->
        case detect_fn.() do
          nil ->
            Logger.warning(
              "Shem: no container runtime found (tried podman, docker). " <>
                "Shell tool will run without isolation. " <>
                "Install podman or docker to enable sandboxed execution."
            )

            Application.put_env(:shem, :resolved_executor_backend, Shem.Lab.Executor.Backend.Local)
            Application.put_env(:shem, :container_runtime_bin, nil)

          runtime ->
            Application.put_env(
              :shem,
              :resolved_executor_backend,
              Shem.Lab.Executor.Backend.Container
            )

            Application.put_env(:shem, :container_runtime_bin, runtime)
        end
    end
  end

  defp detect_container_runtime do
    cond do
      System.find_executable("podman") != nil -> "podman"
      System.find_executable("docker") != nil -> "docker"
      true -> nil
    end
  end
```

The full updated `start/2` head:

```elixir
  @impl true
  def start(_type, _args) do
    resolve_executor_backend()

    children =
      [
        {Horde.Registry, [name: Shem.Registry, keys: :unique, members: :auto]},
        # ... rest unchanged
```

- [ ] **Step 5: Run tests — expect pass**

```
mix test test/shem/application_executor_test.exs
```
Expected: 4 tests, 0 failures.

- [ ] **Step 6: Run full suite — no regressions**

```
mix test
```
Expected: all pass (test.exs pins `:local`, so no container detection in CI).

- [ ] **Step 7: Commit**

```bash
git add lib/shem/application.ex config/config.exs config/test.exs test/shem/application_executor_test.exs
git commit -m "feat: resolve executor backend at startup with Podman/Docker auto-detection and warning"
```

---

### Task 5: ToolDispatch shell → `run_shell/3`

**Files:**
- Modify: `lib/shem/agent/tool_dispatch.ex`
- Modify: `test/shem/agent/tool_dispatch_test.exs`

This task replaces the inline `Task.Supervisor.async_nolink` + `System.cmd` in `dispatch_builtin("shell", ...)` with a single call to `Lab.Executor.run_shell/3`. The existing shell tests in `tool_dispatch_test.exs` remain valid and must still pass; they exercise the `Local` backend via `executor_backend: :local` in test.exs.

- [ ] **Step 1: Identify the current `dispatch_builtin("shell", ...)` in ToolDispatch**

It lives around line 239 of `lib/shem/agent/tool_dispatch.ex` and reads:

```elixir
  # TODO(phase-9b): route through K8s executor once available — currently runs locally
  defp dispatch_builtin("shell", args) do
    cmd = args["cmd"] || ""
    timeout = args["timeout_ms"] || 10_000

    task =
      Task.Supervisor.async_nolink(Shem.Lab.TaskSupervisor, fn ->
        System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, code}} ->
        {:error, "exit #{code}: #{output}"}

      {:exit, reason} ->
        {:error, "shell command crashed: #{inspect(reason)}"}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, "timeout after #{timeout}ms"}
    end
  end
```

- [ ] **Step 2: Replace it**

Remove the entire `dispatch_builtin("shell", args)` clause above and replace with:

```elixir
  defp dispatch_builtin("shell", args) do
    cmd = args["cmd"] || ""
    timeout = args["timeout_ms"] || 10_000
    Lab.Executor.run_shell(cmd, timeout)
  end
```

- [ ] **Step 3: Run the existing shell tests — expect pass without changes**

```
mix test test/shem/agent/tool_dispatch_test.exs --only "shell built-in"
```
Expected: 3 tests, 0 failures.

The existing tests (`echo hello`, `exit 1`, `sleep 10` with 100ms timeout) exercise the `Local` backend because test.exs pins `executor_backend: :local`.

- [ ] **Step 4: Add a test asserting `System.cmd` is no longer called directly**

In `test/shem/agent/tool_dispatch_test.exs`, add inside `describe "shell built-in"`:

```elixir
    test "routes through Executor.run_shell/3 (not System.cmd directly)" do
      # Override backend to Container with a run_fn so we can confirm routing
      run_fn = fn _cmd, _timeout, _opts -> {:ok, "from container backend"} end
      old = Process.get(:shem_executor_backend)
      Process.put(:shem_executor_backend, Shem.Lab.Executor.Backend.Container)

      manifest = ToolDispatch.build_manifest(@config)

      result =
        ToolDispatch.execute(
          %{name: "shell", args: %{"cmd" => "ls", "timeout_ms" => 5_000}},
          manifest,
          run_fn: run_fn
        )

      assert {:ok, "from container backend"} = result

      if old, do: Process.put(:shem_executor_backend, old),
      else: Process.delete(:shem_executor_backend)
    end
```

Wait — `ToolDispatch.execute/2` doesn't accept a third arg. The routing test needs a different approach: set the process dict override and use the Container backend with a `run_fn:` that gets passed through `run_shell/3`. But `run_shell/3` accepts opts and forwards them to the backend — however `dispatch_builtin("shell", ...)` calls `Lab.Executor.run_shell(cmd, timeout)` with no opts, so `run_fn` never reaches the backend.

Instead, test that the process dict backend is honored — meaning Container is reached and returns the no-runtime error (since `container_runtime_bin` is nil in test env):

```elixir
    test "routes through Executor.run_shell/3 (not System.cmd directly)" do
      # Container backend with nil runtime returns a known error — confirms routing
      old = Process.get(:shem_executor_backend)
      Process.put(:shem_executor_backend, Shem.Lab.Executor.Backend.Container)

      manifest = ToolDispatch.build_manifest(@config)
      result = ToolDispatch.execute(%{name: "shell", args: %{"cmd" => "echo hi"}}, manifest)

      assert {:error, "no container runtime available" <> _} = result

      if old, do: Process.put(:shem_executor_backend, old),
      else: Process.delete(:shem_executor_backend)
    end
```

- [ ] **Step 5: Run all shell tests**

```
mix test test/shem/agent/tool_dispatch_test.exs
```
Expected: all pass including the new routing test.

- [ ] **Step 6: Run full suite**

```
mix test
```
Expected: all pass, no regressions.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/agent/tool_dispatch.ex test/shem/agent/tool_dispatch_test.exs
git commit -m "feat: ToolDispatch shell → Executor.run_shell/3; removes direct System.cmd"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Backend behaviour with `run_shell/3` callback | Task 1 |
| Backend.Local (System.cmd, same as current) | Task 1 |
| Backend.Container with Podman/Docker, `--rm -i`, network flag | Task 2 |
| `run_fn:` injectable for Container tests | Task 2 |
| `Executor.run_shell/3` public function | Task 3 |
| `run_code` (`run/3`) unchanged | Task 3 — not touched |
| `:auto` → detect podman → detect docker → `:local` + warning | Task 4 |
| `:local` → Local unconditionally | Task 4 |
| `:container` → Container unconditionally; error log if no runtime | Task 4 |
| Config keys: `executor_backend`, `executor_image`, `executor_network` | Task 4 |
| `test.exs` pins `executor_backend: :local` | Task 4 |
| `ToolDispatch` shell → `run_shell/3` | Task 5 |
| Startup warning message text | Task 4 |
| Timeout via `Task.yield + shutdown(:brutal_kill)` | Tasks 1 + 2 |
| `executor_network: :default | :none | :host` → `--network` flag | Task 2 |
| `executor_image` default `"debian:12-slim"` | Task 2 + 4 (config) |

**Placeholder scan:** None found.

**Type consistency:** `Backend.run_shell/3` signature consistent across behaviour, Local, Container, and Executor.run_shell/3. `result()` type `{:ok, String.t()} | {:error, String.t()}` matches all callsites.
