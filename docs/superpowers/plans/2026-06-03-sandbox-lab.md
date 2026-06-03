# Sandbox Lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Lab workspace, supervised execution harness, graduation gate, and tool registry that will serve as the infrastructure for agent-authored code in Phase 4.

**Architecture:** A layered set of pure modules and one GenServer — `Workspace` manages paths, `Executor` compiles and runs Elixir source in a supervised Task with timeout, `GraduationGate` orchestrates compile→test→graduate, and `Registry` is an ETS-backed GenServer that catalogues graduated tools. All layers are independently testable.

**Tech Stack:** Elixir/OTP, `Task.Supervisor`, `Code.compile_string/1`, `:code.load_binary/3`, `StreamData ~> 1.0`, ETS

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| Create | `lib/shem/tool.ex` | `%Shem.Tool{}` struct |
| Create | `lib/shem/lab/workspace.ex` | Path helpers + disk I/O |
| Create | `lib/shem/lab/executor.ex` | Compile, load, run, unload |
| Create | `lib/shem/lab/graduation_gate.ex` | Compile→test→graduate flow |
| Create | `lib/shem/lab/registry.ex` | ETS-backed tool catalogue |
| Modify | `lib/shem/application.ex` | Add TaskSupervisor + Registry to tree |
| Modify | `lib/shem/tui/app.ex` | Add `tool_count` to model, update on tick |
| Modify | `lib/shem/tui/views/dashboard.ex` | Render live tool count |
| Modify | `mix.exs` | Add `stream_data` dependency |
| Modify | `config/test.exs` | Set `lab_dir` + short executor timeout |
| Create | `test/shem/tool_test.exs` | |
| Create | `test/shem/lab/workspace_test.exs` | |
| Create | `test/shem/lab/executor_test.exs` | |
| Create | `test/shem/lab/registry_test.exs` | |
| Create | `test/shem/lab/graduation_gate_test.exs` | |

---

## Task 1: Add StreamData + configure test environment

**Files:**
- Modify: `mix.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Add stream_data to mix.exs**

```elixir
# lib/shem/mix.exs — replace deps/0 with:
defp deps do
  [
    {:ratatouille, "~> 0.5"},
    {:stream_data, "~> 1.0"}
  ]
end
```

- [ ] **Step 2: Add test config for lab_dir and executor timeout**

```elixir
# config/test.exs — append these two lines:
config :shem, lab_dir: "tmp/test_lab"
config :shem, executor_timeout_ms: 200
```

- [ ] **Step 3: Add `tmp/` to `.gitignore`**

Open `.gitignore` and append:

```
tmp/
```

- [ ] **Step 4: Fetch deps**

Run: `mix deps.get`
Expected: StreamData downloaded and locked.

- [ ] **Step 5: Verify existing tests still pass**

Run: `mix test`
Expected: all existing tests pass (no failures).

- [ ] **Step 6: Commit**

```bash
git add mix.exs mix.lock config/test.exs .gitignore
git commit -m "chore: add stream_data dep, configure test lab_dir"
```

---

## Task 2: `Shem.Tool` struct

**Files:**
- Create: `lib/shem/tool.ex`
- Create: `test/shem/tool_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/shem/tool_test.exs`:

```elixir
defmodule Shem.ToolTest do
  use ExUnit.Case, async: true

  alias Shem.Tool

  test "can be constructed with all required fields" do
    tool = %Tool{
      id: "parse_csv_v1",
      name: "ParseCsv",
      module: ParseCsv,
      source: "defmodule ParseCsv do end",
      test_source: "defmodule ParseCsvTest do def run, do: :ok end",
      graduated_at: ~U[2026-06-03 00:00:00Z]
    }

    assert tool.id == "parse_csv_v1"
    assert tool.module == ParseCsv
    assert tool.constraints == []
    assert tool.metadata == %{}
  end

  test "raises if a required field is missing" do
    assert_raise ArgumentError, fn ->
      struct!(Tool, %{id: "x"})
    end
  end
end
```

- [ ] **Step 2: Run test to confirm it fails**

Run: `mix test test/shem/tool_test.exs`
Expected: `** (UndefinedFunctionError) Shem.Tool` or compile error — module does not exist yet.

- [ ] **Step 3: Implement the struct**

Create `lib/shem/tool.ex`:

```elixir
defmodule Shem.Tool do
  @enforce_keys [:id, :name, :module, :source, :test_source, :graduated_at]
  defstruct [
    :id,
    :name,
    :module,
    :source,
    :test_source,
    :graduated_at,
    constraints: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          module: atom(),
          source: String.t(),
          test_source: String.t(),
          constraints: [String.t()],
          graduated_at: DateTime.t(),
          metadata: map()
        }
end
```

- [ ] **Step 4: Run test to confirm it passes**

Run: `mix test test/shem/tool_test.exs`
Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/tool.ex test/shem/tool_test.exs
git commit -m "feat: Shem.Tool struct — data contract for graduated tools"
```

---

## Task 3: `Shem.Lab.Workspace`

**Files:**
- Create: `lib/shem/lab/workspace.ex`
- Create: `test/shem/lab/workspace_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/shem/lab/workspace_test.exs`:

```elixir
defmodule Shem.Lab.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.Workspace
  alias Shem.Tool

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir)
    on_exit(fn -> File.rm_rf!(lab_dir) end)
    :ok
  end

  test "messy_path/1 returns a path ending in messy/<id>.ex" do
    assert Workspace.messy_path("my_tool") |> String.ends_with?("messy/my_tool.ex")
  end

  test "graduated_path/1 returns a path ending in graduated/<id>.ex" do
    assert Workspace.graduated_path("my_tool") |> String.ends_with?("graduated/my_tool.ex")
  end

  test "graduate/1 writes tool.source to graduated/<id>.ex and returns :ok" do
    tool = %Tool{
      id: "adder_v1",
      name: "Adder",
      module: Adder,
      source: "defmodule Adder do\n  def add(a, b), do: a + b\nend",
      test_source: "",
      graduated_at: DateTime.utc_now()
    }

    assert :ok = Workspace.graduate(tool)
    assert File.read!(Workspace.graduated_path("adder_v1")) == tool.source
  end

  test "list_graduated/0 returns [] when no tools are graduated" do
    assert Workspace.list_graduated() == []
  end

  test "list_graduated/0 returns [{id, path}] tuples after graduation" do
    tool = %Tool{
      id: "multiplier_v1",
      name: "Multiplier",
      module: Multiplier,
      source: "defmodule Multiplier do\n  def mul(a, b), do: a * b\nend",
      test_source: "",
      graduated_at: DateTime.utc_now()
    }

    Workspace.graduate(tool)
    assert [{"multiplier_v1", path}] = Workspace.list_graduated()
    assert String.ends_with?(path, "graduated/multiplier_v1.ex")
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `mix test test/shem/lab/workspace_test.exs`
Expected: compile error — `Shem.Lab.Workspace` does not exist.

- [ ] **Step 3: Implement Workspace**

Create `lib/shem/lab/workspace.ex`:

```elixir
defmodule Shem.Lab.Workspace do
  alias Shem.Tool

  def messy_path(id), do: Path.join([lab_dir(), "messy", "#{id}.ex"])
  def graduated_path(id), do: Path.join([lab_dir(), "graduated", "#{id}.ex"])

  @spec graduate(Tool.t()) :: :ok
  def graduate(%Tool{} = tool) do
    path = graduated_path(tool.id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, tool.source)
  end

  @spec list_graduated() :: [{String.t(), String.t()}]
  def list_graduated do
    dir = Path.join(lab_dir(), "graduated")
    File.mkdir_p!(dir)

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.map(fn filename ->
      id = String.trim_trailing(filename, ".ex")
      {id, Path.join(dir, filename)}
    end)
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

- [ ] **Step 4: Run tests to confirm they pass**

Run: `mix test test/shem/lab/workspace_test.exs`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/lab/workspace.ex test/shem/lab/workspace_test.exs
git commit -m "feat: Lab.Workspace — path management and disk I/O for lab directory"
```

---

## Task 4: Add `Shem.Lab.TaskSupervisor` to supervision tree

**Files:**
- Modify: `lib/shem/application.ex`

- [ ] **Step 1: Add TaskSupervisor as a child**

Edit `lib/shem/application.ex`. Replace the children list:

```elixir
children =
  [
    {Registry, keys: :unique, name: Shem.Registry},
    Shem.AgentSupervisor,
    Shem.EventLog,
    {Task.Supervisor, name: Shem.Lab.TaskSupervisor}
  ] ++ tui_children()
```

- [ ] **Step 2: Verify the app still starts**

Run: `mix test`
Expected: all existing tests pass, no supervisor errors.

- [ ] **Step 3: Commit**

```bash
git add lib/shem/application.ex
git commit -m "feat: add Shem.Lab.TaskSupervisor to supervision tree"
```

---

## Task 5: `Shem.Lab.Executor`

**Files:**
- Create: `lib/shem/lab/executor.ex`
- Create: `test/shem/lab/executor_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/shem/lab/executor_test.exs`:

```elixir
defmodule Shem.Lab.ExecutorTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.Executor

  test "returns {:ok, value} when source compiles and fun succeeds" do
    source = """
    defmodule ExecAdd do
      def add(a, b), do: a + b
    end
    """

    assert {:ok, 7} = Executor.run(source, fn mod -> mod.add(3, 4) end)
  end

  test "returns {:error, :compile, reason} for syntactically invalid source" do
    assert {:error, :compile, reason} =
             Executor.run("this is not valid elixir!!!", fn _ -> :ok end)

    assert is_binary(reason)
  end

  test "returns {:error, :runtime, _} when fun raises" do
    source = """
    defmodule ExecBoom do
      def boom, do: raise "explosion"
    end
    """

    assert {:error, :runtime, _} = Executor.run(source, fn mod -> mod.boom() end)
  end

  test "returns {:error, :timeout} when fun exceeds configured timeout" do
    source = """
    defmodule ExecHang do
      def hang, do: Process.sleep(:infinity)
    end
    """

    assert {:error, :timeout} = Executor.run(source, fn mod -> mod.hang() end, timeout: 50)
  end

  test "loads all modules in source; fun receives the last defined module atom" do
    source = """
    defmodule ExecHelper do
      def val, do: 42
    end

    defmodule ExecMain do
      def result, do: ExecHelper.val() * 2
    end
    """

    assert {:ok, 84} = Executor.run(source, fn mod -> mod.result() end)
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `mix test test/shem/lab/executor_test.exs`
Expected: compile error — `Shem.Lab.Executor` does not exist.

- [ ] **Step 3: Implement Executor**

Create `lib/shem/lab/executor.ex`:

```elixir
defmodule Shem.Lab.Executor do
  @default_timeout 5_000

  @spec run(String.t(), (atom() -> any()), keyword()) ::
          {:ok, any()}
          | {:error, :compile, String.t()}
          | {:error, :timeout}
          | {:error, :runtime, any()}
  def run(source, fun, opts \\ []) do
    timeout =
      Keyword.get(opts, :timeout, Application.get_env(:shem, :executor_timeout_ms, @default_timeout))

    case compile(source) do
      {:ok, modules} ->
        Enum.each(modules, fn {mod, bc} -> :code.load_binary(mod, ~c"nofile", bc) end)
        last_module = modules |> List.last() |> elem(0)
        result = execute(last_module, fun, timeout)
        Enum.each(modules, fn {mod, _} -> :code.purge(mod) && :code.delete(mod) end)
        result

      error ->
        error
    end
  end

  defp compile(source) do
    try do
      case Code.compile_string(source) do
        [] -> {:error, :compile, "source defines no modules"}
        modules -> {:ok, modules}
      end
    rescue
      e -> {:error, :compile, Exception.message(e)}
    end
  end

  defp execute(module, fun, timeout) do
    task = Task.Supervisor.async_nolink(Shem.Lab.TaskSupervisor, fn -> fun.(module) end)

    case Task.yield(task, timeout) do
      {:ok, value} ->
        {:ok, value}

      {:exit, reason} ->
        {:error, :runtime, reason}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end
end
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: `mix test test/shem/lab/executor_test.exs`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Run full suite**

Run: `mix test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/lab/executor.ex test/shem/lab/executor_test.exs
git commit -m "feat: Lab.Executor — supervised compile/run/unload harness with timeout"
```

---

## Task 6: `Shem.Lab.Registry`

**Files:**
- Create: `lib/shem/lab/registry.ex`
- Create: `test/shem/lab/registry_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/shem/lab/registry_test.exs`:

```elixir
defmodule Shem.Lab.RegistryTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.Registry
  alias Shem.Lab.Workspace
  alias Shem.Tool

  @tool %Tool{
    id: "greeter_v1",
    name: "Greeter",
    module: Greeter,
    source: "defmodule Greeter do\n  def hi(name), do: \"Hello, \#{name}\"\nend",
    test_source: "",
    graduated_at: ~U[2026-06-03 00:00:00Z]
  }

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir)
    on_exit(fn -> File.rm_rf!(lab_dir) end)
    :ok
  end

  test "lookup/1 returns {:error, :not_found} for an unknown id" do
    {:ok, pid} = start_supervised({Registry, [name: :test_registry_1]})
    assert {:error, :not_found} = GenServer.call(pid, {:lookup, "nonexistent"})
  end

  test "register/1 makes a tool findable via lookup/1" do
    {:ok, pid} = start_supervised({Registry, [name: :test_registry_2]})
    GenServer.call(pid, {:register, @tool})
    assert {:ok, @tool} = GenServer.call(pid, {:lookup, "greeter_v1"})
  end

  test "all/0 returns an empty list when no tools are registered" do
    {:ok, pid} = start_supervised({Registry, [name: :test_registry_3]})
    assert [] = GenServer.call(pid, :all)
  end

  test "all/0 returns all registered tools" do
    {:ok, pid} = start_supervised({Registry, [name: :test_registry_4]})
    GenServer.call(pid, {:register, @tool})
    tools = GenServer.call(pid, :all)
    assert length(tools) == 1
    assert hd(tools).id == "greeter_v1"
  end

  test "boot scan loads tools pre-written to the graduated directory" do
    Workspace.graduate(@tool)
    {:ok, pid} = start_supervised({Registry, [name: :test_registry_5]})
    tools = GenServer.call(pid, :all)
    assert length(tools) == 1
    assert hd(tools).id == "greeter_v1"
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `mix test test/shem/lab/registry_test.exs`
Expected: compile error — `Shem.Lab.Registry` does not exist.

- [ ] **Step 3: Implement Registry**

Create `lib/shem/lab/registry.ex`:

```elixir
defmodule Shem.Lab.Registry do
  use GenServer

  alias Shem.Lab.Workspace
  alias Shem.Tool

  # ── Client API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec lookup(String.t()) :: {:ok, Tool.t()} | {:error, :not_found}
  def lookup(id), do: GenServer.call(__MODULE__, {:lookup, id})

  @spec all() :: [Tool.t()]
  def all, do: GenServer.call(__MODULE__, :all)

  @spec register(Tool.t()) :: :ok
  def register(%Tool{} = tool), do: GenServer.call(__MODULE__, {:register, tool})

  # ── Server callbacks ────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(:shem_tool_registry, [:set, :protected])
    tools = scan_graduated()
    Enum.each(tools, fn tool -> :ets.insert(table, {tool.id, tool}) end)
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:lookup, id}, _from, state) do
    result =
      case :ets.lookup(state.table, id) do
        [{^id, tool}] -> {:ok, tool}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:all, _from, state) do
    tools = state.table |> :ets.tab2list() |> Enum.map(fn {_id, tool} -> tool end)
    {:reply, tools, state}
  end

  @impl true
  def handle_call({:register, tool}, _from, state) do
    :ets.insert(state.table, {tool.id, tool})
    {:reply, :ok, state}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Phase 3: reads source and builds the catalogue without loading modules into the VM.
  # Module loading at boot is deferred to Phase 4 when tool invocation is needed.
  defp scan_graduated do
    Workspace.list_graduated()
    |> Enum.flat_map(fn {id, path} ->
      with {:ok, source} <- File.read(path),
           {:ok, module} <- extract_module(source) do
        [%Tool{
          id: id,
          name: module |> Atom.to_string() |> String.split(".") |> List.last(),
          module: module,
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

  defp extract_module(source) do
    case Regex.run(~r/defmodule\s+(\S+)\s+do/, source) do
      [_, name] -> {:ok, Module.concat([name])}
      _ -> :error
    end
  end
end
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: `mix test test/shem/lab/registry_test.exs`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/lab/registry.ex test/shem/lab/registry_test.exs
git commit -m "feat: Lab.Registry — ETS-backed tool catalogue with boot scan"
```

---

## Task 7: Wire Registry into the supervision tree

**Files:**
- Modify: `lib/shem/application.ex`

- [ ] **Step 1: Add Registry as a supervised child**

Edit `lib/shem/application.ex`. Replace the children list:

```elixir
children =
  [
    {Registry, keys: :unique, name: Shem.Registry},
    Shem.AgentSupervisor,
    Shem.EventLog,
    {Task.Supervisor, name: Shem.Lab.TaskSupervisor},
    Shem.Lab.Registry
  ] ++ tui_children()
```

- [ ] **Step 2: Run full suite**

Run: `mix test`
Expected: all tests pass. The Registry starts on boot and scans `tmp/test_lab/graduated/` (empty in tests).

- [ ] **Step 3: Commit**

```bash
git add lib/shem/application.ex
git commit -m "feat: add Shem.Lab.Registry to supervision tree"
```

---

## Task 8: `Shem.Lab.GraduationGate`

**Files:**
- Create: `lib/shem/lab/graduation_gate.ex`
- Create: `test/shem/lab/graduation_gate_test.exs`

**Convention for test modules:** The test module must define `run/0` which returns `:ok` on success or raises on failure. The gate calls `test_mod.run()` via the Executor. The naming contract: if the source defines `MyModule`, the test source must define `MyModuleTest`.

- [ ] **Step 1: Write the failing tests**

Create `test/shem/lab/graduation_gate_test.exs`:

```elixir
defmodule Shem.Lab.GraduationGateTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.{GraduationGate, Workspace}

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir)
    on_exit(fn -> File.rm_rf!(lab_dir) end)
    :ok
  end

  # Each test uses a unique module name to avoid Registry contamination — the
  # Registry is app-started and persists across the whole test suite.

  test "returns {:ok, %Tool{}} and writes file when tests pass" do
    source = """
    defmodule GateAdd1 do
      def add(a, b), do: a + b
    end
    """
    test_source = """
    defmodule GateAdd1Test do
      def run do
        unless GateAdd1.add(2, 3) == 5, do: raise "2+3 should be 5"
        :ok
      end
    end
    """
    assert {:ok, tool} = GraduationGate.run(source, test_source)
    assert tool.id == "gate_add1"
    assert tool.module == GateAdd1
    assert tool.source == source
    assert File.exists?(Workspace.graduated_path("gate_add1"))
  end

  test "returns {:error, :gate, ...} when test module's run/0 raises" do
    source = """
    defmodule GateAdd2 do
      def add(a, b), do: a + b
    end
    """
    test_source = """
    defmodule GateAdd2Test do
      def run, do: raise "property violation: broken"
    end
    """
    assert {:error, :gate, _reason} = GraduationGate.run(source, test_source)
    refute File.exists?(Workspace.graduated_path("gate_add2"))
  end

  test "returns {:error, :compile, reason} when test source is syntactically invalid" do
    source = """
    defmodule GateAdd3 do
      def add(a, b), do: a + b
    end
    """
    bad_test = """
    defmodule GateAdd3Test do
      this is not valid elixir
    end
    """
    assert {:error, :compile, reason} = GraduationGate.run(source, bad_test)
    assert is_binary(reason)
  end

  test "stores user-provided constraints on the tool" do
    source = """
    defmodule GateAdd4 do
      def add(a, b), do: a + b
    end
    """
    test_source = """
    defmodule GateAdd4Test do
      def run do
        unless GateAdd4.add(1, 1) == 2, do: raise "broken"
        :ok
      end
    end
    """
    constraints = ["must handle negative numbers", "must return integer"]
    assert {:ok, tool} = GraduationGate.run(source, test_source, constraints)
    assert tool.constraints == constraints
  end

  test "generates versioned id when a tool with the same base id already exists" do
    source_v1 = """
    defmodule GateAdd5 do
      def add(a, b), do: a + b
    end
    """
    test_v1 = """
    defmodule GateAdd5Test do
      def run do
        unless GateAdd5.add(1, 2) == 3, do: raise "broken"
        :ok
      end
    end
    """
    {:ok, _} = GraduationGate.run(source_v1, test_v1)

    source_v2 = """
    defmodule GateAdd5 do
      def add(a, b), do: a + b + 0
    end
    """
    test_v2 = """
    defmodule GateAdd5Test do
      def run do
        unless GateAdd5.add(1, 1) == 2, do: raise "broken"
        :ok
      end
    end
    """
    assert {:ok, tool_v2} = GraduationGate.run(source_v2, test_v2)
    assert tool_v2.id == "gate_add5_v2"
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `mix test test/shem/lab/graduation_gate_test.exs`
Expected: compile error — `Shem.Lab.GraduationGate` does not exist.

- [ ] **Step 3: Implement GraduationGate**

Create `lib/shem/lab/graduation_gate.ex`:

```elixir
defmodule Shem.Lab.GraduationGate do
  alias Shem.Lab.{Workspace, Executor, Registry}
  alias Shem.Tool

  @spec run(String.t(), String.t(), [String.t()]) ::
          {:ok, Tool.t()}
          | {:error, :compile, String.t()}
          | {:error, :gate, any()}
          | {:error, :timeout}
  def run(source, test_source, constraints \\ []) do
    combined = source <> "\n" <> test_source

    case Executor.run(combined, fn test_mod -> test_mod.run() end) do
      {:ok, :ok} ->
        with {:ok, module} <- extract_module(source) do
          id = unique_id(module)
          tool = %Tool{
            id: id,
            name: module |> Atom.to_string() |> String.split(".") |> List.last(),
            module: module,
            source: source,
            test_source: test_source,
            constraints: constraints,
            graduated_at: DateTime.utc_now(),
            metadata: %{}
          }
          :ok = Workspace.graduate(tool)
          :ok = Registry.register(tool)
          {:ok, tool}
        end

      {:error, :compile, reason} ->
        {:error, :compile, reason}

      {:error, :runtime, reason} ->
        {:error, :gate, reason}

      {:error, :timeout} ->
        {:error, :timeout}
    end
  end

  defp extract_module(source) do
    case Regex.run(~r/defmodule\s+(\S+)\s+do/, source) do
      [_, name] -> {:ok, Module.concat([name])}
      _ -> {:error, :compile, "could not determine module name from source"}
    end
  end

  defp unique_id(module) do
    base =
      module
      |> Atom.to_string()
      |> String.split(".")
      |> List.last()
      |> Macro.underscore()

    if Registry.lookup(base) == {:error, :not_found} do
      base
    else
      version =
        Enum.find(2..100, fn v ->
          Registry.lookup("#{base}_v#{v}") == {:error, :not_found}
        end)

      "#{base}_v#{version}"
    end
  end
end
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: `mix test test/shem/lab/graduation_gate_test.exs`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Run full suite**

Run: `mix test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/lab/graduation_gate.ex test/shem/lab/graduation_gate_test.exs
git commit -m "feat: Lab.GraduationGate — compile→test→graduate flow with StreamData convention"
```

---

## Task 9: Wire tool count into TUI dashboard

**Files:**
- Modify: `lib/shem/tui/app.ex`
- Modify: `lib/shem/tui/views/dashboard.ex`

- [ ] **Step 1: Add `tool_count` to TUI model**

Edit `lib/shem/tui/app.ex`. Replace `init/1`, the `:tick` branch in `update/2`, and add a `safe_tool_count/0` helper:

```elixir
@impl true
def init(_context) do
  %{
    mode: :dashboard,
    command_buffer: "",
    paused: false,
    event_log_stats: %{sessions: 0, total_events: 0},
    tool_count: 0
  }
end
```

In `update/2`, replace the `:tick` clause:

```elixir
:tick ->
  %{model | event_log_stats: safe_stats(), tool_count: safe_tool_count()}
```

Add the new private helper (alongside `safe_stats/0`):

```elixir
defp safe_tool_count do
  try do
    Shem.Lab.Registry.all() |> length()
  catch
    :exit, _ -> 0
  end
end
```

- [ ] **Step 2: Wire `tool_count` into the dashboard view**

Edit `lib/shem/tui/views/dashboard.ex`. Replace the hardcoded label:

```elixir
# Old:
label(content: "Tools graduated: 0", color: color(:white))

# New:
label(content: "Tools graduated: #{model.tool_count}", color: color(:white))
```

- [ ] **Step 3: Run full suite**

Run: `mix test`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add lib/shem/tui/app.ex lib/shem/tui/views/dashboard.ex
git commit -m "feat: TUI dashboard shows live graduated tool count from Registry"
```

---

## Verification

- [ ] Run `mix test` — all tests pass, 0 failures
- [ ] Count: previous suite had 76 + 1 doctest; new suite adds ~25 tests
- [ ] Run `mix run --no-halt` — TUI starts, Dashboard shows `Tools graduated: 0`
- [ ] Confirm no files written to `~/.config/shem/` during `mix test`
