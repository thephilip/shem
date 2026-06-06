# Phase 12: Persistent User-Defined Presets — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a DETS-backed `Preset.Store`, config-file loading via `user_presets.exs`, three-layer preset resolution with `:source` annotation, `/preset list|add|delete` TUI commands, and a multiline input mode so users can write real system prompts from the TUI.

**Architecture:** `Preset.Store` is a DETS GenServer (mirrors `Trust.Store`). `Preset.resolve/1` checks built-ins → config → DETS, first match wins. `App` gains two new fields (`multiline_buffer`, `multiline_target`) and a `:multiline_input` mode; multiline clauses sit at the top of `update/2` before all existing handlers. The interactive view renders the multiline editor when the mode is active.

**Tech Stack:** Elixir/OTP, DETS, Ratatouille, ExUnit

---

## File Map

| Action | File |
|---|---|
| Create | `lib/shem/agent/preset_store.ex` |
| Create | `test/shem/agent/preset_store_test.exs` |
| Modify | `lib/shem/application.ex` |
| Modify | `lib/shem/agent/preset.ex` |
| Modify | `test/shem/agent/preset_test.exs` |
| Modify | `config/config.exs` |
| Modify | `lib/shem/tui/command_dispatch.ex` |
| Modify | `test/shem/tui/command_dispatch_test.exs` |
| Modify | `lib/shem/tui/app.ex` |
| Modify | `test/shem/tui/app_test.exs` |
| Modify | `lib/shem/tui/views/interactive.ex` |
| Modify | `test/shem/tui/views/interactive_test.exs` |

---

### Task 1: `Preset.Store` — DETS GenServer

**Files:**
- Create: `lib/shem/agent/preset_store.ex`
- Create: `test/shem/agent/preset_store_test.exs`
- Modify: `lib/shem/application.ex`

- [ ] **Step 1: Write failing tests**

Create `test/shem/agent/preset_store_test.exs`:

```elixir
defmodule Shem.Agent.PresetStoreTest do
  use ExUnit.Case, async: false

  alias Shem.Agent.PresetStore

  setup do
    PresetStore.flush()
    on_exit(fn -> PresetStore.flush() end)
    :ok
  end

  describe "put/2 and get/1" do
    test "get returns {:error, :not_found} for unknown name" do
      assert {:error, :not_found} = PresetStore.get("no_such_preset")
    end

    test "put then get returns the stored preset" do
      :ok = PresetStore.put("my_preset", %{system_prompt: "You are helpful.", tools: :all})
      assert {:ok, preset} = PresetStore.get("my_preset")
      assert preset.system_prompt == "You are helpful."
      assert preset.tools == :all
    end

    test "put overwrites an existing preset" do
      PresetStore.put("my_preset", %{system_prompt: "v1", tools: :all})
      PresetStore.put("my_preset", %{system_prompt: "v2", tools: :all})
      assert {:ok, %{system_prompt: "v2"}} = PresetStore.get("my_preset")
    end
  end

  describe "delete/1" do
    test "delete returns {:error, :not_found} for unknown name" do
      assert {:error, :not_found} = PresetStore.delete("no_such_preset")
    end

    test "delete removes an existing preset" do
      PresetStore.put("to_delete", %{system_prompt: "bye", tools: :all})
      assert :ok = PresetStore.delete("to_delete")
      assert {:error, :not_found} = PresetStore.get("to_delete")
    end
  end

  describe "all/0" do
    test "returns empty map when no presets stored" do
      assert %{} = PresetStore.all()
    end

    test "returns map of all stored presets keyed by name" do
      PresetStore.put("a", %{system_prompt: "A", tools: :all})
      PresetStore.put("b", %{system_prompt: "B", tools: ["read_file"]})
      result = PresetStore.all()
      assert Map.has_key?(result, "a")
      assert Map.has_key?(result, "b")
      assert result["a"].system_prompt == "A"
      assert result["b"].tools == ["read_file"]
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /home/philip/Downloads/_project/shem
mix test test/shem/agent/preset_store_test.exs --seed 0 2>&1 | tail -10
```

Expected: failures — `PresetStore` undefined.

- [ ] **Step 3: Create `lib/shem/agent/preset_store.ex`**

```elixir
defmodule Shem.Agent.PresetStore do
  use GenServer

  @default_path Path.join([System.user_home!(), ".config", "shem", "preset_store.dets"])

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(String.t(), map()) :: :ok
  def put(name, preset) do
    GenServer.call(__MODULE__, {:put, name, preset})
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(name) do
    GenServer.call(__MODULE__, {:delete, name})
  end

  @spec all() :: %{String.t() => map()}
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl true
  def init(opts) do
    path =
      Keyword.get(
        opts,
        :path,
        Application.get_env(:shem, :preset_store_path, @default_path)
      )

    path_charlist = to_charlist(path)
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(path_charlist, type: :set, file: path_charlist) do
      {:ok, table} -> {:ok, %{table: table}}
      {:error, reason} -> {:stop, {:dets_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:put, name, preset}, _from, state) do
    entry = Map.put(preset, :name, name)
    :ok = :dets.insert(state.table, {name, entry})
    {:reply, :ok, state}
  end

  def handle_call({:get, name}, _from, state) do
    result =
      case :dets.lookup(state.table, name) do
        [{^name, entry}] -> {:ok, entry}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call({:delete, name}, _from, state) do
    result =
      case :dets.lookup(state.table, name) do
        [{^name, _}] ->
          :dets.delete(state.table, name)
          :ok

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call(:all, _from, state) do
    result =
      :dets.foldl(
        fn {name, entry}, acc -> Map.put(acc, name, entry) end,
        %{},
        state.table
      )

    {:reply, result, state}
  end

  def handle_call(:flush, _from, state) do
    :dets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    :dets.close(state.table)
  end
end
```

- [ ] **Step 4: Add `Preset.Store` to the supervision tree in `lib/shem/application.ex`**

Find:
```elixir
        Shem.Trust.Store,
```

Replace with:
```elixir
        Shem.Trust.Store,
        Shem.Agent.PresetStore,
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/shem/agent/preset_store_test.exs --seed 0 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/agent/preset_store.ex test/shem/agent/preset_store_test.exs lib/shem/application.ex
git commit -m "feat: Preset.Store — DETS-backed preset persistence"
```

---

### Task 2: `Preset` — three-layer resolution with `:source` annotation

**Files:**
- Modify: `lib/shem/agent/preset.ex`
- Modify: `test/shem/agent/preset_test.exs`

**Context:** `Preset.resolve/1` currently reads only from `Application.get_env(:shem, :agent_presets, @builtin_presets)`. This task splits resolution into three layers: built-in (hardcoded), config (`Application.get_env(:shem, :user_presets, [])`), and dynamic (`PresetStore`). `Preset.all/0` returns all three layers annotated with `:source`.

- [ ] **Step 1: Write failing tests**

`test/shem/agent/preset_test.exs` exists. Add the following `describe` blocks at the end, before the final `end`. First, read the current file to find where to insert:

```bash
cat -n /home/philip/Downloads/_project/shem/test/shem/agent/preset_test.exs
```

Add these blocks at the end:

```elixir
  describe "resolve/1 — dynamic layer" do
    setup do
      Shem.Agent.PresetStore.flush()
      on_exit(fn -> Shem.Agent.PresetStore.flush() end)
      :ok
    end

    test "resolves a preset from PresetStore when not in static layers" do
      Shem.Agent.PresetStore.put("dynamic_one", %{system_prompt: "Dynamic prompt", tools: :all})
      assert {:ok, %{system_prompt: "Dynamic prompt"}} = Preset.resolve("dynamic_one")
    end

    test "static (built-in) preset wins over same-named dynamic preset" do
      Shem.Agent.PresetStore.put("general", %{system_prompt: "Overridden", tools: :all})
      assert {:ok, %{system_prompt: prompt}} = Preset.resolve("general")
      refute prompt == "Overridden"
    end

    test "returns {:error, :not_found} for unknown preset not in any layer" do
      assert {:error, :not_found} = Preset.resolve("__nonexistent__")
    end
  end

  describe "all/0 — source annotation" do
    setup do
      Shem.Agent.PresetStore.flush()
      on_exit(fn -> Shem.Agent.PresetStore.flush() end)
      :ok
    end

    test "built-in presets have source: :builtin" do
      presets = Preset.all()
      builtin = Enum.filter(presets, &(&1.source == :builtin))
      assert length(builtin) >= 3
      assert Enum.any?(builtin, &(&1.name == "general"))
    end

    test "dynamic presets have source: :dynamic" do
      Shem.Agent.PresetStore.put("my_dyn", %{system_prompt: "Dyn", tools: :all})
      presets = Preset.all()
      dynamic = Enum.filter(presets, &(&1.source == :dynamic))
      assert Enum.any?(dynamic, &(&1.name == "my_dyn"))
    end

    test "all/0 returns a flat list" do
      result = Preset.all()
      assert is_list(result)
      assert Enum.all?(result, &is_map/1)
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/agent/preset_test.exs --seed 0 2>&1 | tail -10
```

Expected: failures — `resolve/1` doesn't check PresetStore, `all/0` doesn't annotate `:source`.

- [ ] **Step 3: Replace `lib/shem/agent/preset.ex`**

```elixir
defmodule Shem.Agent.Preset do
  @builtin_presets [
    %{
      name: "general",
      system_prompt:
        "You are a helpful assistant. Think step by step and use available tools to complete the task. When finished, respond with plain text only.",
      tools: :all
    },
    %{
      name: "coding",
      system_prompt:
        "You are an expert Elixir and OTP engineer. Read the relevant code and understand the context before making changes. Use write_file to edit files, shell to run tests (e.g. mix test), and read_file/list_dir to explore. Prefer small, verified changes over large rewrites. When finished, confirm what was done.",
      tools: :all
    },
    %{
      name: "explore",
      system_prompt:
        "You are a read-only code explorer. Your job is to understand and explain code, not to modify it. Use read_file, list_dir, and shell (for grep/find) to explore the codebase. Do not use write_file or write_tool.",
      tools: ["read_file", "list_dir", "shell"]
    }
  ]

  @spec resolve(String.t()) ::
          {:ok, %{system_prompt: String.t(), tools: :all | [String.t()]}}
          | {:error, :not_found}
  def resolve(name) do
    case find_in_static(name) do
      {:ok, preset} ->
        {:ok, Map.take(preset, [:system_prompt, :tools])}

      :error ->
        try do
          case Shem.Agent.PresetStore.get(name) do
            {:ok, preset} -> {:ok, Map.take(preset, [:system_prompt, :tools])}
            {:error, :not_found} -> {:error, :not_found}
          end
        catch
          :exit, _ -> {:error, :not_found}
        end
    end
  end

  @spec all() :: [map()]
  def all do
    builtin = Enum.map(@builtin_presets, &Map.put(&1, :source, :builtin))
    config = Application.get_env(:shem, :user_presets, []) |> Enum.map(&Map.put(&1, :source, :config))

    dynamic =
      try do
        Shem.Agent.PresetStore.all()
        |> Map.values()
        |> Enum.map(&Map.put(&1, :source, :dynamic))
      catch
        :exit, _ -> []
      end

    builtin ++ config ++ dynamic
  end

  defp find_in_static(name) do
    static = @builtin_presets ++ Application.get_env(:shem, :user_presets, [])

    case Enum.find(static, &(&1.name == name)) do
      nil -> :error
      preset -> {:ok, preset}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/agent/preset_test.exs --seed 0 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 5: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/agent/preset.ex test/shem/agent/preset_test.exs
git commit -m "feat: Preset — three-layer resolution with :source annotation"
```

---

### Task 3: Config — conditional `user_presets.exs` import

**Files:**
- Modify: `config/config.exs`

- [ ] **Step 1: Update `config/config.exs`**

Replace the entire file with:

```elixir
import Config

config :shem, trust_gate_enabled: true

if File.exists?("config/user_presets.exs"), do: import_config("user_presets.exs")

import_config "#{config_env()}.exs"
```

- [ ] **Step 2: Run full suite to confirm no regressions**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass (the file doesn't exist in the repo, so the `import_config` is skipped).

- [ ] **Step 3: Commit**

```bash
git add config/config.exs
git commit -m "config: conditionally import user_presets.exs if present"
```

---

### Task 4: `CommandDispatch` — `/preset` subcommands

**Files:**
- Modify: `lib/shem/tui/command_dispatch.ex`
- Modify: `test/shem/tui/command_dispatch_test.exs`

- [ ] **Step 1: Write failing tests**

Add the following `describe` block at the end of `test/shem/tui/command_dispatch_test.exs`, before the final `end`:

```elixir
  describe "parse/1 — /preset command" do
    test "/preset list returns {:preset_list}" do
      assert {:preset_list} = CommandDispatch.parse("/preset list")
    end

    test "/preset add <name> returns {:preset_add, name}" do
      assert {:preset_add, "my_preset"} = CommandDispatch.parse("/preset add my_preset")
    end

    test "/preset add trims whitespace from name" do
      assert {:preset_add, "my_preset"} = CommandDispatch.parse("/preset add  my_preset  ")
    end

    test "/preset delete <name> returns {:preset_delete, name}" do
      assert {:preset_delete, "my_preset"} = CommandDispatch.parse("/preset delete my_preset")
    end

    test "/preset with no subcommand returns error" do
      assert {:error, msg} = CommandDispatch.parse("/preset")
      assert msg =~ "usage: /preset"
    end

    test "/preset add with no name returns error" do
      assert {:error, msg} = CommandDispatch.parse("/preset add")
      assert msg =~ "usage: /preset add"
    end

    test "/preset delete with no name returns error" do
      assert {:error, msg} = CommandDispatch.parse("/preset delete")
      assert msg =~ "usage: /preset delete"
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/tui/command_dispatch_test.exs --seed 0 2>&1 | tail -10
```

Expected: failures — `/preset` parsed as unknown command.

- [ ] **Step 3: Update `lib/shem/tui/command_dispatch.ex`**

Replace the entire file with:

```elixir
defmodule Shem.TUI.CommandDispatch do
  @spec parse(String.t()) ::
          {:start_agent, String.t(), String.t()}
          | {:stop_agent}
          | {:list_agents}
          | {:redteam, String.t()}
          | {:tools}
          | {:trust, String.t()}
          | {:preset_list}
          | {:preset_add, String.t()}
          | {:preset_delete, String.t()}
          | {:error, String.t()}
  def parse(""), do: {:error, "empty input"}

  def parse("/" <> rest) do
    parts = String.split(rest, " ", trim: true)

    case parts do
      ["agent", preset | task_parts] when task_parts != [] ->
        {:start_agent, preset, Enum.join(task_parts, " ")}

      ["agent" | _] ->
        {:error, "usage: /agent <preset> <task>"}

      ["stop"] ->
        {:stop_agent}

      ["agents"] ->
        {:list_agents}

      ["tools" | _] ->
        {:tools}

      ["trust" | name_parts] ->
        name = String.trim(Enum.join(name_parts, " "))
        if name == "", do: {:error, "usage: /trust <tool_name>"}, else: {:trust, name}

      ["redteam" | tool_parts] ->
        name = String.trim(Enum.join(tool_parts, " "))
        if name == "", do: {:error, "usage: /redteam <tool_name>"}, else: {:redteam, name}

      ["preset", "list" | _] ->
        {:preset_list}

      ["preset", "add" | name_parts] ->
        name = String.trim(Enum.join(name_parts, " "))
        if name == "", do: {:error, "usage: /preset add <name>"}, else: {:preset_add, name}

      ["preset", "delete" | name_parts] ->
        name = String.trim(Enum.join(name_parts, " "))
        if name == "", do: {:error, "usage: /preset delete <name>"}, else: {:preset_delete, name}

      ["preset" | _] ->
        {:error, "usage: /preset <list|add|delete> ..."}

      _ ->
        {:error, "unknown command: /#{rest}"}
    end
  end

  def parse(text) do
    trimmed = String.trim(text)
    if trimmed == "", do: {:error, "empty input"}, else: {:start_agent, "general", trimmed}
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/tui/command_dispatch_test.exs --seed 0 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 5: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/command_dispatch.ex test/shem/tui/command_dispatch_test.exs
git commit -m "feat: CommandDispatch — /preset list|add|delete commands"
```

---

### Task 5: `App` — multiline mode, preset handlers

**Files:**
- Modify: `lib/shem/tui/app.ex`
- Modify: `test/shem/tui/app_test.exs`

**Context:** The App currently has two modes (`:dashboard`, `:interactive`). This task adds `:multiline_input` and two new model fields. Multiline clauses sit at the TOP of `update/2` before all existing clauses, guarded by `when model.mode == :multiline_input`. The three preset command handlers are added inside the existing `{:event, %{key: @enter}}` clause.

- [ ] **Step 1: Write failing tests**

Add the following `describe` blocks at the end of `test/shem/tui/app_test.exs`, before the final `end`:

```elixir
  describe "init/1 — Phase 12 fields" do
    test "model has multiline_buffer defaulting to []" do
      assert App.init(%{}).multiline_buffer == []
    end

    test "model has multiline_target defaulting to nil" do
      assert App.init(%{}).multiline_target == nil
    end
  end

  describe "update/2 — /preset add enters multiline mode" do
    test "{:preset_add, name} switches mode to :multiline_input" do
      model = %{App.init(%{}) | command_buffer: "/preset add my_preset"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.mode == :multiline_input
      assert result.multiline_target == {:preset_add, "my_preset"}
      assert result.multiline_buffer == []
      assert result.command_buffer == ""
    end
  end

  describe "update/2 — multiline mode" do
    setup do
      Shem.Agent.PresetStore.flush()
      on_exit(fn -> Shem.Agent.PresetStore.flush() end)
      :ok
    end

    test "Enter appends command_buffer as a line and clears buffer" do
      model = %{App.init(%{}) | mode: :multiline_input, multiline_target: {:preset_add, "p"}, command_buffer: "line one"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.multiline_buffer == ["line one"]
      assert result.command_buffer == ""
      assert result.mode == :multiline_input
    end

    test "Enter with '/done' submits, saves preset, returns to :interactive" do
      model = %{App.init(%{}) | mode: :multiline_input, multiline_target: {:preset_add, "new_p"}, multiline_buffer: ["You are a reviewer."], command_buffer: "/done"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.mode == :interactive
      assert result.multiline_buffer == []
      assert result.multiline_target == nil
      assert result.command_buffer == ""
      assert is_binary(result.command_output)
      assert result.command_output =~ "new_p"
      assert {:ok, _} = Shem.Agent.PresetStore.get("new_p")
    end

    test "Escape cancels and returns to :interactive" do
      model = %{App.init(%{}) | mode: :multiline_input, multiline_target: {:preset_add, "p"}, multiline_buffer: ["some line"], command_buffer: "partial"}
      result = App.update(model, {:event, %{ch: 0, key: 27}})
      assert result.mode == :interactive
      assert result.multiline_buffer == []
      assert result.multiline_target == nil
      assert result.command_buffer == ""
    end

    test "typing appends to command_buffer" do
      model = %{App.init(%{}) | mode: :multiline_input, multiline_target: {:preset_add, "p"}, command_buffer: "hel"}
      result = App.update(model, {:event, %{ch: ?l, key: 0}})
      assert result.command_buffer == "hell"
    end
  end

  describe "update/2 — /preset list and /preset delete" do
    setup do
      Shem.Agent.PresetStore.flush()
      on_exit(fn -> Shem.Agent.PresetStore.flush() end)
      :ok
    end

    test "{:preset_list} sets command_output to a binary" do
      model = %{App.init(%{}) | command_buffer: "/preset list"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert is_binary(result.command_output)
    end

    test "{:preset_delete} on a built-in sets command_error" do
      model = %{App.init(%{}) | command_buffer: "/preset delete general"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_error =~ "cannot delete"
    end

    test "{:preset_delete} on a dynamic preset removes it and sets command_output" do
      Shem.Agent.PresetStore.put("temp_preset", %{system_prompt: "temp", tools: :all})
      model = %{App.init(%{}) | command_buffer: "/preset delete temp_preset"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_output =~ "temp_preset"
      assert {:error, :not_found} = Shem.Agent.PresetStore.get("temp_preset")
    end

    test "{:preset_delete} on unknown preset sets command_error" do
      model = %{App.init(%{}) | command_buffer: "/preset delete __nope__"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_error =~ "unknown preset"
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/tui/app_test.exs --seed 0 2>&1 | tail -10
```

Expected: failures — `multiline_buffer` and `multiline_target` not in model, preset handlers missing.

- [ ] **Step 3: Replace `lib/shem/tui/app.ex`**

```elixir
defmodule Shem.TUI.App do
  @behaviour Ratatouille.App

  alias Shem.TUI.Views.{Dashboard, Interactive}
  alias Shem.TUI.{CommandDispatch, AgentView}
  alias Ratatouille.Runtime.Subscription

  @esc 27
  @backspace 127
  @space ?\s
  @enter 13
  @tab 9

  @impl true
  def init(_context) do
    %{
      mode: :dashboard,
      command_buffer: "",
      paused: false,
      event_log_stats: %{sessions: 0, total_events: 0},
      tool_count: 0,
      mcp_client_count: 0,
      mcp_outbound_count: 0,
      cluster_node_count: 1,
      agents: [],
      focused_agent: nil,
      agent_view: nil,
      command_error: nil,
      command_output: nil,
      trust_counts: %{high: 0, medium: 0, low: 0, unrated: 0},
      multiline_buffer: [],
      multiline_target: nil
    }
  end

  @impl true
  def subscribe(_model) do
    Subscription.interval(500, :tick)
  end

  @impl true
  def update(model, msg) do
    case msg do
      # --- Multiline input mode (must be first) ---
      {:event, %{key: @esc}} when model.mode == :multiline_input ->
        %{model | mode: :interactive, multiline_buffer: [], multiline_target: nil, command_buffer: "", command_error: nil}

      {:event, %{key: @enter}} when model.mode == :multiline_input and model.command_buffer == "/done" ->
        text = Enum.join(model.multiline_buffer, "\n")
        submit_multiline(model, text)

      {:event, %{key: @enter}} when model.mode == :multiline_input ->
        %{model | multiline_buffer: model.multiline_buffer ++ [model.command_buffer], command_buffer: ""}

      {:event, %{key: @backspace}} when model.mode == :multiline_input ->
        buf = model.command_buffer
        %{model | command_buffer: if(buf == "", do: "", else: String.slice(buf, 0..-2//1))}

      {:event, %{ch: ch}} when model.mode == :multiline_input and ch > 0 ->
        %{model | command_buffer: model.command_buffer <> <<ch::utf8>>}

      {:event, _} when model.mode == :multiline_input ->
        model

      # --- Normal mode ---
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

      {:event, %{key: @tab}} when model.command_buffer == "" ->
        case model.agents do
          [] ->
            model

          agents ->
            names = Enum.map(agents, & &1.name)

            next =
              case model.focused_agent do
                nil ->
                  List.first(names)

                current ->
                  idx = Enum.find_index(names, &(&1 == current)) || 0
                  Enum.at(names, rem(idx + 1, length(names)))
              end

            %{model | focused_agent: next}
        end

      {:event, %{key: @enter}} when model.command_buffer != "" ->
        case CommandDispatch.parse(model.command_buffer) do
          {:start_agent, preset_name, task} ->
            case Shem.Agent.start_with_preset(preset_name, task) do
              {:ok, name} ->
                %{model | command_buffer: "", focused_agent: name, command_error: nil, command_output: nil}

              {:error, reason} ->
                %{model | command_error: "failed to start agent: #{inspect(reason)}", command_output: nil}
            end

          {:stop_agent} ->
            if model.focused_agent, do: Shem.Agent.stop(model.focused_agent)
            %{model | command_buffer: "", command_error: nil, command_output: nil}

          {:list_agents} ->
            %{model | command_buffer: "", command_error: nil, command_output: nil}

          {:tools} ->
            output = format_tools()
            %{model | command_buffer: "", command_output: output, command_error: nil}

          {:trust, tool_name} ->
            case Shem.Lab.Registry.lookup_by_name(tool_name) do
              {:ok, tool} ->
                output = format_trust(tool)
                %{model | command_buffer: "", command_output: output, command_error: nil}

              {:error, :not_found} ->
                %{model | command_error: "unknown tool: #{tool_name}", command_output: nil}
            end

          {:redteam, tool_name} ->
            case Shem.Lab.Registry.lookup_by_name(tool_name) do
              {:ok, tool} ->
                Shem.Adversarial.start_hardening(tool.id)
                %{model | command_buffer: "", command_error: nil, command_output: nil}

              {:error, :not_found} ->
                %{model | command_error: "unknown tool: #{tool_name}", command_output: nil}
            end

          {:preset_list} ->
            output = format_presets()
            %{model | command_buffer: "", command_output: output, command_error: nil}

          {:preset_add, name} ->
            %{model |
              mode: :multiline_input,
              multiline_target: {:preset_add, name},
              multiline_buffer: [],
              command_buffer: "",
              command_error: nil,
              command_output: nil
            }

          {:preset_delete, name} ->
            case Enum.find(Shem.Agent.Preset.all(), &(&1.name == name)) do
              nil ->
                %{model | command_error: "unknown preset: #{name}", command_output: nil}

              %{source: :builtin} ->
                %{model | command_error: "cannot delete built-in preset: #{name}", command_output: nil}

              %{source: :config} ->
                %{model | command_error: "cannot delete config preset: #{name}", command_output: nil}

              %{source: :dynamic} ->
                Shem.Agent.PresetStore.delete(name)
                %{model | command_buffer: "", command_output: "preset '#{name}' deleted", command_error: nil}
            end

          {:error, reason} ->
            %{model | command_error: reason, command_output: nil}
        end

      :tick ->
        %{
          model
          | event_log_stats: safe_stats(),
            tool_count: safe_tool_count(),
            mcp_client_count: safe_mcp_count(),
            mcp_outbound_count: safe_mcp_outbound_count(),
            cluster_node_count: safe_cluster_count(),
            agents: safe_agent_list(),
            agent_view: safe_agent_view(model.focused_agent),
            trust_counts: safe_trust_counts()
        }

      _ ->
        model
    end
  end

  @impl true
  def render(model) do
    case model.mode do
      :dashboard -> Dashboard.render(model)
      :interactive -> Interactive.render(model)
      :multiline_input -> Interactive.render(model)
    end
  end

  defp submit_multiline(model, text) do
    case model.multiline_target do
      {:preset_add, name} ->
        Shem.Agent.PresetStore.put(name, %{system_prompt: text, tools: :all})

        %{model |
          mode: :interactive,
          multiline_buffer: [],
          multiline_target: nil,
          command_buffer: "",
          command_output: "preset '#{name}' saved",
          command_error: nil
        }
    end
  end

  defp format_presets do
    try do
      presets = Shem.Agent.Preset.all()

      if presets == [] do
        "No presets defined."
      else
        header = "Presets (#{length(presets)})\n"

        lines =
          Enum.map(presets, fn p ->
            source_str = String.pad_trailing("[#{p.source}]", 12)
            tools_str = if p.tools == :all, do: "all tools", else: Enum.join(p.tools, ", ")
            "  #{String.pad_trailing(p.name, 20)} #{source_str}  #{tools_str}"
          end)

        header <> Enum.join(lines, "\n")
      end
    catch
      :exit, _ -> "Preset data unavailable."
    end
  end

  defp format_tools do
    try do
      tools = Shem.Lab.Registry.all()
      scored = Shem.Trust.Store.all()

      if tools == [] do
        "No Lab tools graduated yet."
      else
        header = "Lab Tools (#{length(tools)})\n"

        lines =
          Enum.map(tools, fn tool ->
            {band, hardenings} =
              case Map.fetch(scored, tool.id) do
                {:ok, score} ->
                  count =
                    case Shem.Trust.Store.entry(tool.id) do
                      {:ok, entry} -> entry.hardening_count
                      _ -> 0
                    end

                  {score_to_band(score), count}

                :error ->
                  {:unrated, 0}
              end

            count_str = if hardenings == 1, do: "1 hardening", else: "#{hardenings} hardenings"
            "  #{String.pad_trailing(tool.name, 24)} #{String.pad_trailing(to_string(band), 10)} #{count_str}"
          end)

        header <> Enum.join(lines, "\n")
      end
    catch
      :exit, _ -> "Trust data unavailable."
    end
  end

  defp format_trust(tool) do
    try do
      case Shem.Trust.Store.entry(tool.id) do
        {:ok, entry} ->
          band = score_to_band(entry.score)
          updated = Calendar.strftime(entry.last_updated, "%Y-%m-%d %H:%M:%SZ")

          "#{tool.name}\n" <>
            "  band:       #{band}\n" <>
            "  score:      #{Float.round(entry.score, 3)}\n" <>
            "  hardenings: #{entry.hardening_count}\n" <>
            "  updated:    #{updated}"

        {:error, :unrated} ->
          "#{tool.name}\n  band: unrated\n  never hardened"
      end
    catch
      :exit, _ -> "#{tool.name}\n  trust data unavailable"
    end
  end

  defp safe_trust_counts do
    try do
      all_tools = Shem.Lab.Registry.all()
      scored = Shem.Trust.Store.all()
      base = %{high: 0, medium: 0, low: 0, unrated: 0}

      Enum.reduce(all_tools, base, fn tool, acc ->
        band =
          case Map.fetch(scored, tool.id) do
            {:ok, score} -> score_to_band(score)
            :error -> :unrated
          end

        Map.update!(acc, band, &(&1 + 1))
      end)
    catch
      :exit, _ -> %{high: 0, medium: 0, low: 0, unrated: 0}
    end
  end

  defp score_to_band(score) when score >= 0.8, do: :high
  defp score_to_band(score) when score >= 0.5, do: :medium
  defp score_to_band(_), do: :low

  defp safe_stats do
    try do
      Shem.EventLog.stats()
    catch
      :exit, _ -> %{sessions: 0, total_events: 0}
    end
  end

  defp safe_tool_count do
    try do
      Shem.Lab.Registry.all() |> length()
    catch
      :exit, _ -> 0
    end
  end

  defp safe_mcp_count do
    try do
      Shem.MCP.SessionRegistry.client_count()
    catch
      :exit, _ -> 0
    end
  end

  defp safe_mcp_outbound_count do
    try do
      Shem.MCP.Client.connected_servers()
      |> Enum.count(&(&1.status == :ready))
    catch
      :exit, _ -> 0
    end
  end

  defp safe_cluster_count do
    Shem.Cluster.nodes() |> length()
  end

  defp safe_agent_list do
    try do
      Horde.DynamicSupervisor.which_children(Shem.AgentSupervisor)
      |> Enum.filter(fn {_id, pid, _, _} -> is_pid(pid) end)
      |> Enum.map(fn {id, pid, _, _} ->
        status =
          case GenServer.call(pid, :status, 100) do
            {:ok, s} -> s
            _ -> :unknown
          end

        session_id =
          case GenServer.call(pid, :session_id, 100) do
            s when is_binary(s) -> s
            _ -> nil
          end

        %{name: id, pid: pid, status: status, session_id: session_id, turn_count: 0}
      end)
    catch
      :exit, _ -> []
    end
  end

  defp safe_agent_view(nil), do: nil

  defp safe_agent_view(name) do
    try do
      via = Shem.ProcessRegistry.via_tuple(name)

      case GenServer.whereis(via) do
        nil ->
          nil

        pid ->
          case GenServer.call(pid, :session_id, 200) do
            session_id when is_binary(session_id) ->
              case AgentView.build(session_id) do
                {:ok, view} -> %{view | agent_name: name}
                :not_found -> nil
              end

            _ ->
              nil
          end
      end
    catch
      :exit, _ -> nil
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/tui/app_test.exs --seed 0 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/app.ex test/shem/tui/app_test.exs
git commit -m "feat: App — multiline input mode, /preset list|add|delete handlers"
```

---

### Task 6: Interactive view — multiline editor rendering

**Files:**
- Modify: `lib/shem/tui/views/interactive.ex`
- Modify: `test/shem/tui/views/interactive_test.exs`

**Context:** `App.render/1` now delegates `:multiline_input` mode to `Interactive.render/1`. This task adds a new clause at the top of `Interactive.render/1` that pattern-matches `mode: :multiline_input` and renders the multiline editor. It also updates the "No active session" hint to show all presets dynamically.

- [ ] **Step 1: Write failing tests**

Add the following `describe` block at the end of `test/shem/tui/views/interactive_test.exs`, before the final `end`:

```elixir
  describe "render/1 — :multiline_input mode" do
    test "render/1 shows multiline editor panel when mode is :multiline_input" do
      model = %{base_model() |
        mode: :multiline_input,
        multiline_target: {:preset_add, "my_preset"},
        multiline_buffer: ["You are a reviewer.", "Be thorough."],
        command_buffer: "partial line"
      }
      rendered = Interactive.render(model) |> inspect(limit: :infinity)
      assert rendered =~ "my_preset"
      assert rendered =~ "You are a reviewer."
      assert rendered =~ "/done"
    end

    test "render/1 in :multiline_input does not show 'No active session'" do
      model = %{base_model() |
        mode: :multiline_input,
        multiline_target: {:preset_add, "p"},
        multiline_buffer: [],
        command_buffer: ""
      }
      rendered = Interactive.render(model) |> inspect(limit: :infinity)
      refute rendered =~ "No active session"
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/tui/views/interactive_test.exs --seed 0 2>&1 | tail -10
```

Expected: failures — no `:multiline_input` clause in `render/1`.

- [ ] **Step 3: Add multiline render clause to `lib/shem/tui/views/interactive.ex`**

Add this new `render/1` clause at the very top of the file, BEFORE the existing `def render(model)` function:

```elixir
  def render(%{mode: :multiline_input} = model) do
    name =
      case model.multiline_target do
        {:preset_add, n} -> n
        _ -> "input"
      end

    view do
      row do
        column(size: 8) do
          panel(title: "Shem // New Preset · #{name}", color: color(:cyan)) do
            label(
              content: "Type lines. Enter '/done' to save, Esc to cancel.",
              color: color(:yellow)
            )

            label(content: "")

            for line <- model.multiline_buffer do
              label(content: line, color: color(:white))
            end

            label(content: "▸ #{model.command_buffer}_", color: color(:cyan))
          end
        end

        column(size: 4) do
          render_event_log(model)
        end
      end

      row do
        column(size: 12) do
          render_agent_switcher(model)
        end
      end

      row do
        column(size: 12) do
          panel(title: "Multiline Input · /done to submit · Esc to cancel", color: color(:yellow)) do
            label(content: "", color: color(:white))
          end
        end
      end
    end
  end

```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/shem/tui/views/interactive_test.exs --seed 0 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 5: Full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tui/views/interactive.ex test/shem/tui/views/interactive_test.exs
git commit -m "feat: Interactive view — multiline input mode rendering"
```

---

## Self-Review

**Spec coverage:**
- ✅ `Preset.Store` with `put/get/delete/all/flush` — Task 1
- ✅ Added to supervision tree — Task 1 Step 4
- ✅ Three-layer resolution: built-in → config → dynamic — Task 2
- ✅ Built-in wins over same-named dynamic — Task 2 (`find_in_static` checked first)
- ✅ `Preset.all/0` annotates `:source` — Task 2
- ✅ `try/catch :exit, _` on dynamic layer calls in `Preset` — Task 2
- ✅ `config/user_presets.exs` conditional import — Task 3
- ✅ `/preset list` → `{:preset_list}` — Task 4
- ✅ `/preset add <name>` → `{:preset_add, name}` — Task 4
- ✅ `/preset delete <name>` → `{:preset_delete, name}` — Task 4
- ✅ `/preset` no subcommand → error — Task 4
- ✅ `multiline_buffer` and `multiline_target` model fields — Task 5
- ✅ `:multiline_input` mode — Task 5
- ✅ Multiline clauses at TOP of `update/2` before all others — Task 5
- ✅ Enter appends line — Task 5
- ✅ `/done` submits and saves preset — Task 5
- ✅ Escape cancels and returns to `:interactive` — Task 5
- ✅ `{:preset_list}` sets `command_output` — Task 5
- ✅ `{:preset_delete}` refuses built-in/config, deletes dynamic — Task 5
- ✅ `App.render/1` dispatches `:multiline_input` to `Interactive.render/1` — Task 5
- ✅ `Interactive.render/1` multiline clause shows collected lines + hint — Task 6

**Placeholder scan:** None.

**Type consistency:**
- `PresetStore.put/2` stores `%{name:, system_prompt:, tools:}`, `get/1` returns same shape — used consistently in `submit_multiline/2` and `format_presets/0` ✅
- `Preset.all/0` returns list of maps with `:source` key — used in `{:preset_delete}` handler and `format_presets/0` ✅
- `multiline_target` shape `{:preset_add, name}` — set in `{:preset_add}` handler, matched in `submit_multiline/2` and `Interactive.render/1` ✅
- `multiline_buffer` is `[String.t()]` — initialized as `[]`, appended with `++ [command_buffer]`, joined with `"\n"` on submit ✅
