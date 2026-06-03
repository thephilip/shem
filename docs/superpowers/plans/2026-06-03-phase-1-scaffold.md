# Phase 1: Project Scaffold, OTP Supervision Tree & TUI Skeleton

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bootstrap the Shem Elixir application with a working OTP supervision tree, process registry, dynamic agent supervisor, and a keyboard-driven Ratatouille TUI that renders a two-mode (Dashboard / Interactive) skeleton.

**Architecture:** A standard `--sup` Mix application where the root `Application` module starts a `Registry` for named process lookup, a `DynamicSupervisor` for future agent processes, and a `Ratatouille.Runtime` TUI process — all three under a single root `Supervisor`. The TUI is a pure state machine (model → update → render) and is fully unit-tested without spawning a real terminal.

**Tech Stack:** Elixir 1.17+, OTP 27+, `ratatouille ~> 0.5`, ExUnit

---

## File Map

| File | Purpose |
|---|---|
| `mix.exs` | Project config and deps |
| `config/config.exs` | Base config — imports env-specific config |
| `config/dev.exs` | Dev config (TUI enabled) |
| `config/test.exs` | Test config (TUI disabled) |
| `lib/shem/application.ex` | OTP Application — root supervision tree |
| `lib/shem/process_registry.ex` | Named-process registry wrapper |
| `lib/shem/agent_supervisor.ex` | DynamicSupervisor for agent processes |
| `lib/shem/tui/app.ex` | Ratatouille.App — model/update/render state machine |
| `lib/shem/tui/views/dashboard.ex` | Dashboard/Ops mode render component |
| `lib/shem/tui/views/interactive.ex` | Interactive/Dev mode render component |
| `lib/shem/tui/runtime_supervisor.ex` | Wraps Ratatouille.Runtime under supervision |
| `test/shem/process_registry_test.exs` | Registry unit tests |
| `test/shem/agent_supervisor_test.exs` | DynamicSupervisor unit tests |
| `test/shem/tui/app_test.exs` | TUI state machine unit tests |
| `test/shem/tui/views/dashboard_test.exs` | Dashboard render unit tests |

---

### Task 1: Install Elixir and Erlang/OTP

**Files:** none (system setup)

- [ ] **Step 1: Install Elixir and Erlang via paru**

```bash
paru -S elixir
```

This pulls in `erlang-nox` as a dependency automatically. Accept all prompts.

- [ ] **Step 2: Verify installation**

```bash
elixir --version
mix --version
```

Expected output (versions may differ):
```
Erlang/OTP 27 [erts-15.x] ...
Elixir 1.17.x (compiled with Erlang/OTP 27)
Mix 1.17.x (compiled with Erlang/OTP 27)
```

- [ ] **Step 3: Install Hex (Elixir package manager)**

```bash
mix local.hex --force
mix local.rebar --force
```

Expected: `Hex 2.x.x installed` / `Rebar3 x.x.x installed`

---

### Task 2: Initialize the Mix project

**Files:** `mix.exs`, `lib/shem.ex`, `lib/shem/application.ex`, `test/shem_test.exs`, `test/test_helper.exs`

- [ ] **Step 1: Run mix new in the current directory**

From `/home/philip/Downloads/_project/shem/`:
```bash
mix new . --app shem --sup
```

The `--sup` flag generates an `Application` module with a `Supervisor`. The existing `agent-framework.md` and `docs/` folder are untouched. If prompted to overwrite any file, say `n` (there shouldn't be any conflicts).

Expected: lines like `* creating lib/shem/application.ex`, `* creating mix.exs`, etc.

- [ ] **Step 2: Verify the generated structure**

```bash
find . -name "*.ex" -o -name "*.exs" | grep -v deps | sort
```

Expected:
```
./lib/shem.ex
./lib/shem/application.ex
./mix.exs
./test/shem_test.exs
./test/test_helper.exs
```

- [ ] **Step 3: Run the default test suite — confirm a clean baseline**

```bash
mix test
```

Expected: `1 doctest, 1 test, 0 failures`

- [ ] **Step 4: Initialize git and commit baseline**

```bash
git init
git add mix.exs lib/ test/ .formatter.exs .gitignore
git commit -m "chore: mix new shem --sup baseline"
```

---

### Task 3: Add dependencies

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Update the deps function in mix.exs**

Open `mix.exs`. Replace the `defp deps` block (which currently returns `[]`) with:

```elixir
defp deps do
  [
    {:ratatouille, "~> 0.5"}
  ]
end
```

- [ ] **Step 2: Fetch deps**

```bash
mix deps.get
```

Expected: `Resolving Hex dependencies... Resolution completed in...` with no errors. A `mix.lock` file is created.

- [ ] **Step 3: Compile to catch any issues**

```bash
mix compile
```

Expected: `Generated shem app` with no warnings.

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "chore: add ratatouille dependency"
```

---

### Task 4: Process Registry

**Files:**
- Create: `lib/shem/process_registry.ex`
- Create: `test/shem/process_registry_test.exs`
- Modify: `lib/shem/application.ex`

- [ ] **Step 1: Write the failing test**

Create `test/shem/process_registry_test.exs`:

```elixir
defmodule Shem.ProcessRegistryTest do
  use ExUnit.Case, async: true

  alias Shem.ProcessRegistry

  test "via_tuple/1 returns a correctly shaped Registry via-tuple" do
    assert {:via, Registry, {Shem.Registry, :my_agent}} =
             ProcessRegistry.via_tuple(:my_agent)
  end

  test "a process started with a via_tuple can be looked up in the Registry" do
    name = :"test_proc_#{System.unique_integer([:positive])}"
    via = ProcessRegistry.via_tuple(name)

    {:ok, pid} = Agent.start_link(fn -> 0 end, name: via)

    assert [{^pid, nil}] = Registry.lookup(Shem.Registry, name)
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
mix test test/shem/process_registry_test.exs
```

Expected: compilation error — `Shem.ProcessRegistry` does not exist yet.

- [ ] **Step 3: Create the module**

Create `lib/shem/process_registry.ex`:

```elixir
defmodule Shem.ProcessRegistry do
  @registry Shem.Registry

  @spec via_tuple(term()) :: {:via, Registry, {atom(), term()}}
  def via_tuple(name), do: {:via, Registry, {@registry, name}}
end
```

- [ ] **Step 4: Start the Registry in Application**

Replace the contents of `lib/shem/application.ex` with:

```elixir
defmodule Shem.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Shem.Registry}
    ]

    opts = [strategy: :one_for_one, name: Shem.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

- [ ] **Step 5: Run the tests**

```bash
mix test test/shem/process_registry_test.exs
```

Expected: `2 tests, 0 failures`

- [ ] **Step 6: Commit**

```bash
git add lib/shem/process_registry.ex lib/shem/application.ex test/shem/process_registry_test.exs
git commit -m "feat: process registry with via_tuple helper"
```

---

### Task 5: Agent DynamicSupervisor

**Files:**
- Create: `lib/shem/agent_supervisor.ex`
- Create: `test/shem/agent_supervisor_test.exs`
- Modify: `lib/shem/application.ex`

- [ ] **Step 1: Write the failing tests**

Create `test/shem/agent_supervisor_test.exs`:

```elixir
defmodule Shem.AgentSupervisorTest do
  use ExUnit.Case, async: false

  alias Shem.AgentSupervisor

  test "start_agent/2 starts a live process under the supervisor" do
    {:ok, pid} = AgentSupervisor.start_agent(
      :"agent_#{System.unique_integer([:positive])}",
      fn -> :idle end
    )
    assert Process.alive?(pid)
  end

  test "start_agent/2 registers the process by name in Shem.Registry" do
    name = :"named_#{System.unique_integer([:positive])}"
    {:ok, _pid} = AgentSupervisor.start_agent(name, fn -> 42 end)

    via = Shem.ProcessRegistry.via_tuple(name)
    pid = GenServer.whereis(via)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "a supervised agent process is restarted when it crashes" do
    name = :"crash_#{System.unique_integer([:positive])}"
    {:ok, pid} = AgentSupervisor.start_agent(name, fn -> :ok end)

    Process.exit(pid, :kill)
    Process.sleep(100)

    via = Shem.ProcessRegistry.via_tuple(name)
    new_pid = GenServer.whereis(via)
    assert is_pid(new_pid)
    assert new_pid != pid
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
mix test test/shem/agent_supervisor_test.exs
```

Expected: compilation error — `Shem.AgentSupervisor` does not exist.

- [ ] **Step 3: Create the module**

Create `lib/shem/agent_supervisor.ex`:

```elixir
defmodule Shem.AgentSupervisor do
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_agent(term(), (-> any())) :: DynamicSupervisor.on_start_child()
  def start_agent(name, init_fn) do
    via = Shem.ProcessRegistry.via_tuple(name)

    child_spec = %{
      id: name,
      start: {Agent, :start_link, [init_fn, [name: via]]},
      restart: :permanent
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
end
```

- [ ] **Step 4: Add AgentSupervisor to Application**

Replace `lib/shem/application.ex`:

```elixir
defmodule Shem.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Shem.Registry},
      Shem.AgentSupervisor
    ]

    opts = [strategy: :one_for_one, name: Shem.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

- [ ] **Step 5: Run the tests**

```bash
mix test test/shem/agent_supervisor_test.exs
```

Expected: `3 tests, 0 failures`

- [ ] **Step 6: Run the full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/agent_supervisor.ex lib/shem/application.ex test/shem/agent_supervisor_test.exs
git commit -m "feat: DynamicSupervisor for agent processes with auto-restart"
```

---

### Task 6: TUI App — State Machine (model / update)

**Files:**
- Create: `lib/shem/tui/app.ex`
- Create: `test/shem/tui/app_test.exs`

The TUI is a pure Elixir state machine. These tests exercise `init/1` and `update/2` as plain functions — no terminal process involved.

- [ ] **Step 1: Write the failing tests**

Create `test/shem/tui/app_test.exs`:

```elixir
defmodule Shem.TUI.AppTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.App

  describe "init/1" do
    test "default model starts in dashboard mode, unpaused, with empty buffer" do
      model = App.init(%{})
      assert model.mode == :dashboard
      assert model.command_buffer == ""
      assert model.paused == false
    end
  end

  describe "update/2 — mode switching" do
    test "'d' key switches to dashboard mode" do
      model = %{App.init(%{}) | mode: :interactive}
      result = App.update(model, {:event, %{ch: ?d, key: 0}})
      assert result.mode == :dashboard
    end

    test "'i' key switches to interactive mode" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: ?i, key: 0}})
      assert result.mode == :interactive
    end

    test "mode keys are ignored while command buffer is open" do
      model = %{App.init(%{}) | command_buffer: "/st"}
      result = App.update(model, {:event, %{ch: ?i, key: 0}})
      assert result.mode == :dashboard
    end
  end

  describe "update/2 — pause and resume" do
    test "space key toggles paused on" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: 0, key: ?\s}})
      assert result.paused == true
    end

    test "space key toggles paused off when already paused" do
      model = %{App.init(%{}) | paused: true}
      result = App.update(model, {:event, %{ch: 0, key: ?\s}})
      assert result.paused == false
    end

    test "esc key (27) always pauses" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: 0, key: 27}})
      assert result.paused == true
    end

    test "pause keys are ignored while command buffer is open" do
      model = %{App.init(%{}) | command_buffer: "/"}
      result = App.update(model, {:event, %{ch: 0, key: ?\s}})
      assert result.paused == false
    end
  end

  describe "update/2 — command buffer" do
    test "'/' opens the command buffer" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: ?/, key: 0}})
      assert result.command_buffer == "/"
    end

    test "characters append to the buffer when it is active" do
      model = %{App.init(%{}) | command_buffer: "/"}
      result = App.update(model, {:event, %{ch: ?s, key: 0}})
      assert result.command_buffer == "/s"
    end

    test "backspace (127) removes the last character" do
      model = %{App.init(%{}) | command_buffer: "/st"}
      result = App.update(model, {:event, %{ch: 0, key: 127}})
      assert result.command_buffer == "/s"
    end

    test "backspace on empty buffer is a no-op" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: 0, key: 127}})
      assert result.command_buffer == ""
    end

    test "backspace on single-char buffer clears it" do
      model = %{App.init(%{}) | command_buffer: "/"}
      result = App.update(model, {:event, %{ch: 0, key: 127}})
      assert result.command_buffer == ""
    end
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
mix test test/shem/tui/app_test.exs
```

Expected: compilation error — `Shem.TUI.App` does not exist.

- [ ] **Step 3: Implement the App module**

Create `lib/shem/tui/app.ex`:

```elixir
defmodule Shem.TUI.App do
  @behaviour Ratatouille.App

  alias Shem.TUI.Views.{Dashboard, Interactive}

  # Keyboard constants (termbox key codes)
  @esc 27
  @backspace 127
  @space ?\s

  @impl true
  def init(_context) do
    %{
      mode: :dashboard,
      command_buffer: "",
      paused: false
    }
  end

  @impl true
  def update(model, msg) do
    case msg do
      {:event, %{ch: ?d, key: 0}} when model.command_buffer == "" ->
        %{model | mode: :dashboard}

      {:event, %{ch: ?i, key: 0}} when model.command_buffer == "" ->
        %{model | mode: :interactive}

      {:event, %{key: @space}} when model.command_buffer == "" ->
        %{model | paused: !model.paused}

      {:event, %{key: @esc}} when model.command_buffer == "" ->
        %{model | paused: true}

      {:event, %{ch: ?/}} when model.command_buffer == "" ->
        %{model | command_buffer: "/"}

      {:event, %{key: @backspace}} ->
        buf = model.command_buffer
        %{model | command_buffer: if(buf == "", do: "", else: String.slice(buf, 0..-2//1))}

      {:event, %{ch: ch}} when model.command_buffer != "" and ch > 0 ->
        %{model | command_buffer: model.command_buffer <> <<ch::utf8>>}

      _ ->
        model
    end
  end

  @impl true
  def render(model) do
    case model.mode do
      :dashboard -> Dashboard.render(model)
      :interactive -> Interactive.render(model)
    end
  end
end
```

- [ ] **Step 4: Run the tests**

```bash
mix test test/shem/tui/app_test.exs
```

Expected: `11 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add lib/shem/tui/app.ex test/shem/tui/app_test.exs
git commit -m "feat: TUI app state machine — init, update, command buffer, pause"
```

---

### Task 7: TUI Views — Dashboard and Interactive

**Files:**
- Create: `lib/shem/tui/views/dashboard.ex`
- Create: `lib/shem/tui/views/interactive.ex`
- Create: `test/shem/tui/views/dashboard_test.exs`

- [ ] **Step 1: Write failing tests for the Dashboard view**

Create `test/shem/tui/views/dashboard_test.exs`:

```elixir
defmodule Shem.TUI.Views.DashboardTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.Views.Dashboard

  defp base_model, do: %{mode: :dashboard, command_buffer: "", paused: false}

  test "render/1 returns a Ratatouille view element (map with tag: :view)" do
    result = Dashboard.render(base_model())
    assert is_map(result)
    assert result.tag == :view
  end

  test "render/1 shows PAUSED when model.paused is true" do
    model = %{base_model() | paused: true}
    rendered = Dashboard.render(model) |> inspect()
    assert rendered =~ "PAUSED"
  end

  test "render/1 shows the command buffer content when it is active" do
    model = %{base_model() | command_buffer: "/style"}
    rendered = Dashboard.render(model) |> inspect()
    assert rendered =~ "/style"
  end

  test "render/1 shows keybinding hints in the default state" do
    rendered = Dashboard.render(base_model()) |> inspect()
    assert rendered =~ "Dashboard"
  end
end
```

- [ ] **Step 2: Run to confirm failure**

```bash
mix test test/shem/tui/views/dashboard_test.exs
```

Expected: compilation error.

- [ ] **Step 3: Create the Dashboard view**

Create `lib/shem/tui/views/dashboard.ex`:

```elixir
defmodule Shem.TUI.Views.Dashboard do
  import Ratatouille.View
  import Ratatouille.Constants, only: [color: 1, attribute: 1]

  def render(model) do
    view do
      row do
        column(size: 8) do
          panel(title: "Shem // Dashboard", color: color(:green)) do
            label(content: "Agents: 0 active", color: color(:white))
            label(content: "")
            label(content: "CPU: --   MEM: --   GPU: --", color: color(:cyan))
            label(content: "")
            label(
              content: "Token spend: $0.0000 session / $0.0000 lifetime",
              color: color(:yellow)
            )
          end
        end

        column(size: 4) do
          panel(title: "Lab Status", color: color(:magenta)) do
            label(content: "Tools graduated: 0", color: color(:white))
            label(content: "Active loops:    0", color: color(:white))
            label(content: "")
            label(
              content: "Lab: idle",
              attributes: [attribute(:italic)],
              color: color(:magenta)
            )
          end
        end
      end

      row do
        column(size: 12) do
          panel(title: status_bar_title(model), color: status_bar_color(model)) do
            label(
              content: status_bar_content(model),
              attributes: [attribute(:italic)],
              color: color(:white)
            )
          end
        end
      end
    end
  end

  defp status_bar_title(%{paused: true}),
    do: "[ PAUSED — press SPACE to resume ]"

  defp status_bar_title(%{command_buffer: "/" <> _ = buf}),
    do: "Command: #{buf}"

  defp status_bar_title(_),
    do: "Ready  |  d=Dashboard  i=Interactive  /=Command  SPACE=Pause  ESC=Pause"

  defp status_bar_color(%{paused: true}), do: color(:red)
  defp status_bar_color(_), do: color(:green)

  defp status_bar_content(%{paused: true}),
    do: "Agent loop suspended. Type a prompt to steer, then SPACE to resume."

  defp status_bar_content(%{command_buffer: ""}), do: "Shem is watching."
  defp status_bar_content(%{command_buffer: buf}), do: buf
end
```

- [ ] **Step 4: Create the Interactive view**

Create `lib/shem/tui/views/interactive.ex`:

```elixir
defmodule Shem.TUI.Views.Interactive do
  import Ratatouille.View
  import Ratatouille.Constants, only: [color: 1, attribute: 1]

  def render(model) do
    view do
      row do
        column(size: 8) do
          panel(title: "Shem // Interactive · Agent Output", color: color(:cyan)) do
            label(
              content: "No active session.",
              attributes: [attribute(:italic)],
              color: color(:white)
            )
            label(content: "")
            label(
              content: "Start an agent to stream output here.",
              attributes: [attribute(:italic)],
              color: color(:cyan)
            )
          end
        end

        column(size: 4) do
          panel(title: "Execution Log", color: color(:yellow)) do
            label(
              content: "No events yet.",
              attributes: [attribute(:italic)],
              color: color(:yellow)
            )
          end
        end
      end

      row do
        column(size: 12) do
          panel(title: prompt_title(model), color: prompt_color(model)) do
            label(
              content: prompt_content(model),
              attributes: [attribute(:italic)],
              color: color(:white)
            )
          end
        end
      end
    end
  end

  defp prompt_title(%{paused: true}), do: "[ PAUSED — press SPACE to resume ]"
  defp prompt_title(%{command_buffer: "/" <> _ = buf}), do: "Command: #{buf}"
  defp prompt_title(_), do: "d=Dashboard  /=Command  SPACE=Pause"

  defp prompt_color(%{paused: true}), do: color(:red)
  defp prompt_color(_), do: color(:cyan)

  defp prompt_content(%{paused: true}), do: "PAUSED — press SPACE to resume."
  defp prompt_content(%{command_buffer: ""}), do: "> _"
  defp prompt_content(%{command_buffer: buf}), do: buf
end
```

- [ ] **Step 5: Run the view tests**

```bash
mix test test/shem/tui/views/dashboard_test.exs
```

Expected: `4 tests, 0 failures`

- [ ] **Step 6: Run the full suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/tui/views/ test/shem/tui/views/
git commit -m "feat: TUI dashboard and interactive view components"
```

---

### Task 8: TUI Runtime Supervisor + Environment Config

**Files:**
- Create: `lib/shem/tui/runtime_supervisor.ex`
- Create: `config/config.exs`
- Create: `config/dev.exs`
- Create: `config/test.exs`
- Modify: `lib/shem/application.ex`

The TUI runtime must NOT start during `mix test` — it would try to claim the terminal. We gate it via `Application.get_env`.

- [ ] **Step 1: Create the runtime supervisor**

Create `lib/shem/tui/runtime_supervisor.ex`:

```elixir
defmodule Shem.TUI.RuntimeSupervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Ratatouille.Runtime, app: Shem.TUI.App, quit_events: [{:key, 3}]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

`key: 3` is Ctrl+C in termbox — quits the runtime cleanly.

- [ ] **Step 2: Create config files**

Check whether `config/config.exs` already exists:

```bash
ls config/ 2>/dev/null || echo "config dir missing"
```

If `config/config.exs` **does not exist**, create `config/config.exs`:

```elixir
import Config

import_config "#{config_env()}.exs"
```

If it **already exists** (Mix `--sup` creates it), open it and add the `import_config` line if it isn't there.

Create `config/dev.exs`:

```elixir
import Config

config :shem, start_tui: true
```

Create `config/test.exs`:

```elixir
import Config

config :shem, start_tui: false
```

- [ ] **Step 3: Gate TUI startup in Application**

Replace `lib/shem/application.ex`:

```elixir
defmodule Shem.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Shem.Registry},
        Shem.AgentSupervisor
      ] ++ tui_children()

    opts = [strategy: :one_for_one, name: Shem.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp tui_children do
    if Application.get_env(:shem, :start_tui, true) do
      [Shem.TUI.RuntimeSupervisor]
    else
      []
    end
  end
end
```

- [ ] **Step 4: Run the full test suite — confirm no terminal errors**

```bash
mix test
```

Expected: all tests pass, no termbox/runtime errors.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/tui/runtime_supervisor.ex lib/shem/application.ex config/
git commit -m "feat: wire TUI runtime under supervision, disabled in test env"
```

---

### Task 9: Smoke Test — Boot the Live TUI

**Files:** none new

- [ ] **Step 1: Start the application**

```bash
mix run --no-halt
```

Expected: a full-screen TUI appears. You should see the Dashboard panel with:
- "Agents: 0 active"
- "CPU: -- MEM: -- GPU: --"
- Token spend counters
- Lab Status panel (right side)
- Green status bar: "Ready | d=Dashboard i=Interactive /=Command SPACE=Pause"

- [ ] **Step 2: Test mode switching and input**

- Press `i` → title changes to "Shem // Interactive · Agent Output"
- Press `d` → returns to Dashboard
- Press `SPACE` → status bar turns red, shows "PAUSED"
- Press `SPACE` → resumes, turns green
- Press `/` → status bar shows "Command: /"
- Type `style` → bar shows "/style"
- Press backspace repeatedly → characters removed
- Press `Ctrl+C` → exits cleanly back to shell prompt

- [ ] **Step 3: Final commit**

```bash
git add .
git commit -m "chore: phase 1 complete — OTP scaffold, registry, agent supervisor, TUI skeleton"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Covered by |
|---|---|
| `mix new`, process registry, supervisor tree | Tasks 2, 4, 5 |
| TUI core: rendering and input handling | Tasks 6, 7, 8 |
| Dashboard/Ops mode | Task 7 (Dashboard view) |
| Interactive/Dev mode | Task 7 (Interactive view) |
| Slash command buffer (`/`) | Task 6 (App update) |
| Pause-and-steer (SPACE/ESC) | Task 6 (App update) |
| Hot-key mode switching (`d`/`i`) | Task 6 (App update) |
| High-contrast ANSI colors (neon red errors, emerald green, dim italic) | Tasks 7 |
| TUI supervised under Application | Tasks 8 |

**Deferred to later phases (by design):** MCP adapter, Bumblebee/Ollama, agent self-learning loop, event-sourced timeline engine, adversarial loop, BEAM distribution, trust-weighted consensus, Lab sandbox.

**Placeholder scan:** None — every step has actual code, exact commands, and expected output.

**Type/name consistency:** `model.command_buffer`, `model.paused`, `model.mode` used uniformly across `App`, `Dashboard`, and `Interactive`. `Shem.Registry` atom used consistently in `ProcessRegistry` and `Application`.
