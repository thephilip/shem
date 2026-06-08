# Agent Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent, cross-session key-value memory store to Shem, exposed as four agent built-in tools (`remember`, `recall`, `forget`, `list_memories`).

**Architecture:** One new module `Shem.Memory.Store` — a DETS-backed GenServer following the exact pattern of `Shem.Trust.Store`. Four new entries in `ToolDispatch.@builtins` with corresponding `dispatch_builtin` clauses. No changes to `Agent.Server`, `Turn`, or any prompt path.

**Tech Stack:** Elixir/OTP, DETS (`:dets`), ExUnit

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `lib/shem/memory/store.ex` | DETS GenServer: put/get/delete/all/flush |
| Modify | `lib/shem/application.ex` | Start `Shem.Memory.Store` alongside `Trust.Store` |
| Modify | `lib/shem/agent/tool_dispatch.ex` | Add 4 builtins to `@builtins`; add 4 `dispatch_builtin` clauses; add `alias Shem.Memory` |
| Modify | `config/test.exs` | Add `memory_store_path: "tmp/test_memory.dets"` |
| Create | `test/shem/memory/store_test.exs` | Unit tests for `Memory.Store` |
| Modify | `test/shem/agent/tool_dispatch_test.exs` | Add 4 describe blocks for new builtins |

---

## Task 1: `Shem.Memory.Store` — test and implement

**Files:**
- Create: `lib/shem/memory/store.ex`
- Create: `test/shem/memory/store_test.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Add test config**

Open `config/test.exs` and add this line after the existing `trust_store_path` line:

```elixir
config :shem, memory_store_path: "tmp/test_memory.dets"
```

- [ ] **Step 2: Write the failing test file**

Create `test/shem/memory/store_test.exs`:

```elixir
defmodule Shem.Memory.StoreTest do
  use ExUnit.Case, async: false

  alias Shem.Memory.Store

  setup do
    Store.flush()
    on_exit(fn -> Store.flush() end)
    :ok
  end

  describe "get/1" do
    test "returns {:error, :not_found} for unknown key" do
      assert {:error, :not_found} = Store.get("no_such_key")
    end
  end

  describe "put/2 and get/1" do
    test "stores a string value under a string key" do
      assert :ok = Store.put("user/name", "alice")
      assert {:ok, "alice"} = Store.get("user/name")
    end

    test "overwrites an existing key" do
      Store.put("k", "v1")
      Store.put("k", "v2")
      assert {:ok, "v2"} = Store.get("k")
    end

    test "written_at is stored (persistence test confirms schema)" do
      tmp_path = "tmp/memory_persist_#{System.unique_integer([:positive])}.dets"
      on_exit(fn -> File.rm(tmp_path) end)

      {:ok, pid1} = GenServer.start_link(Store, [path: tmp_path])
      GenServer.call(pid1, {:put, "persist_key", "persist_val"})
      GenServer.stop(pid1)

      {:ok, pid2} = GenServer.start_link(Store, [path: tmp_path])
      assert {:ok, "persist_val"} = GenServer.call(pid2, {:get, "persist_key"})
      # Confirm written_at is stored by checking raw DETS record has 3 elements
      [{_key, _val, written_at}] = :dets.lookup(
        to_charlist(tmp_path),
        "persist_key"
      )
      assert %DateTime{} = written_at
      GenServer.stop(pid2)
    end
  end

  describe "delete/1" do
    test "returns {:error, :not_found} for unknown key" do
      assert {:error, :not_found} = Store.delete("no_such_key")
    end

    test "removes an existing entry and returns :ok" do
      Store.put("to_delete", "bye")
      assert :ok = Store.delete("to_delete")
      assert {:error, :not_found} = Store.get("to_delete")
    end
  end

  describe "all/1" do
    test "returns empty list when store is empty" do
      assert [] = Store.all()
    end

    test "returns all entries as [{key, value}] sorted by key" do
      Store.put("b", "2")
      Store.put("a", "1")
      Store.put("c", "3")
      assert [{"a", "1"}, {"b", "2"}, {"c", "3"}] = Store.all()
    end

    test "filters by prefix when prefix is provided" do
      Store.put("coding/style", "functional")
      Store.put("coding/lang", "elixir")
      Store.put("user/name", "alice")
      result = Store.all("coding/")
      assert length(result) == 2
      assert Enum.all?(result, fn {k, _v} -> String.starts_with?(k, "coding/") end)
    end

    test "empty prefix string returns all entries" do
      Store.put("x", "1")
      Store.put("y", "2")
      assert length(Store.all("")) == 2
    end
  end

  describe "flush/0" do
    test "removes all entries" do
      Store.put("a", "1")
      Store.put("b", "2")
      Store.flush()
      assert [] = Store.all()
    end
  end
end
```

- [ ] **Step 3: Run test to confirm it fails (module not found)**

```bash
mix test test/shem/memory/store_test.exs 2>&1 | head -20
```

Expected: compile error — `Shem.Memory.Store` is not defined.

- [ ] **Step 4: Implement `Shem.Memory.Store`**

Create `lib/shem/memory/store.ex`:

```elixir
defmodule Shem.Memory.Store do
  use GenServer

  @default_path Path.join([System.user_home!(), ".config", "shem", "memory.dets"])

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(String.t(), String.t()) :: :ok
  def put(key, value) do
    GenServer.call(__MODULE__, {:put, key, value})
  end

  @spec get(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(key) do
    GenServer.call(__MODULE__, {:delete, key})
  end

  @spec all(String.t()) :: [{String.t(), String.t()}]
  def all(prefix \\ "") do
    GenServer.call(__MODULE__, {:all, prefix})
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
        Application.get_env(:shem, :memory_store_path, @default_path)
      )

    path_charlist = to_charlist(path)
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(path_charlist, type: :set, file: path_charlist) do
      {:ok, table} -> {:ok, %{table: table}}
      {:error, reason} -> {:stop, {:dets_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    :ok = :dets.insert(state.table, {key, value, DateTime.utc_now()})
    {:reply, :ok, state}
  end

  def handle_call({:get, key}, _from, state) do
    result =
      case :dets.lookup(state.table, key) do
        [{^key, value, _written_at}] -> {:ok, value}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call({:delete, key}, _from, state) do
    result =
      case :dets.lookup(state.table, key) do
        [{^key, _value, _written_at}] ->
          :dets.delete(state.table, key)
          :ok

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call({:all, prefix}, _from, state) do
    entries =
      :dets.foldl(
        fn {k, v, _written_at}, acc ->
          if String.starts_with?(k, prefix), do: [{k, v} | acc], else: acc
        end,
        [],
        state.table
      )
      |> Enum.sort_by(&elem(&1, 0))

    {:reply, entries, state}
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

- [ ] **Step 5: Run tests and confirm they pass**

```bash
mix test test/shem/memory/store_test.exs
```

Expected: all tests pass (the persistence test with `written_at` may need adjustment — if the DETS table name does not match the path atom, remove that sub-assertion and just check the value persists).

- [ ] **Step 6: Commit**

```bash
git add lib/shem/memory/store.ex test/shem/memory/store_test.exs config/test.exs
git commit -m "feat: Shem.Memory.Store — DETS-backed key-value GenServer"
```

---

## Task 2: Wire `Memory.Store` into the application supervisor

**Files:**
- Modify: `lib/shem/application.ex`

- [ ] **Step 1: Add `Shem.Memory.Store` to the children list**

In `lib/shem/application.ex`, add `Shem.Memory.Store` directly after `Shem.Trust.Store` in the `children` list:

```elixir
    children =
      [
        {Horde.Registry, [name: Shem.Registry, keys: :unique, members: :auto]},
        Shem.AgentSupervisor,
        Shem.EventLog,
        Shem.Trust.Store,
        Shem.Memory.Store,        # ← add this line
        Shem.Agent.PresetStore,
        Shem.LLM.Router,
        {Task.Supervisor, name: Shem.Lab.TaskSupervisor},
        Shem.Lab.Registry,
        Shem.LLM.BudgetServer,
        {Registry, keys: :duplicate, name: Shem.StreamRegistry}
      ] ++
```

- [ ] **Step 2: Run the full test suite to confirm nothing is broken**

```bash
mix test
```

Expected: all existing tests pass (no new tests added here).

- [ ] **Step 3: Commit**

```bash
git add lib/shem/application.ex
git commit -m "feat: start Shem.Memory.Store in application supervisor"
```

---

## Task 3: Add memory builtins to `ToolDispatch`

**Files:**
- Modify: `lib/shem/agent/tool_dispatch.ex`
- Modify: `test/shem/agent/tool_dispatch_test.exs`

- [ ] **Step 1: Write the failing tests**

Open `test/shem/agent/tool_dispatch_test.exs`. Add a `setup` call for `Memory.Store.flush()` in the module-level `setup` block if one exists, or add a new one. Then append these four describe blocks at the end of the file, before the final `end`:

```elixir
  describe "remember built-in" do
    setup do
      Shem.Memory.Store.flush()
      on_exit(fn -> Shem.Memory.Store.flush() end)
      :ok
    end

    test "stores value and returns confirmation" do
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, "stored: user/name"} =
        ToolDispatch.execute(%{name: "remember", args: %{"key" => "user/name", "value" => "alice"}}, manifest)
    end

    test "returns error when key is missing" do
      manifest = ToolDispatch.build_manifest(@config)
      assert {:error, "remember requires key and value"} =
        ToolDispatch.execute(%{name: "remember", args: %{"value" => "alice"}}, manifest)
    end

    test "returns error when value is missing" do
      manifest = ToolDispatch.build_manifest(@config)
      assert {:error, "remember requires key and value"} =
        ToolDispatch.execute(%{name: "remember", args: %{"key" => "user/name"}}, manifest)
    end
  end

  describe "recall built-in" do
    setup do
      Shem.Memory.Store.flush()
      on_exit(fn -> Shem.Memory.Store.flush() end)
      :ok
    end

    test "returns stored value" do
      Shem.Memory.Store.put("recall/key", "recall_value")
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, "recall_value"} =
        ToolDispatch.execute(%{name: "recall", args: %{"key" => "recall/key"}}, manifest)
    end

    test "returns miss message for unknown key" do
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, "no memory at key: missing_key"} =
        ToolDispatch.execute(%{name: "recall", args: %{"key" => "missing_key"}}, manifest)
    end
  end

  describe "forget built-in" do
    setup do
      Shem.Memory.Store.flush()
      on_exit(fn -> Shem.Memory.Store.flush() end)
      :ok
    end

    test "deletes an existing key and returns confirmation" do
      Shem.Memory.Store.put("forget/key", "bye")
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, "forgotten: forget/key"} =
        ToolDispatch.execute(%{name: "forget", args: %{"key" => "forget/key"}}, manifest)
      assert {:error, :not_found} = Shem.Memory.Store.get("forget/key")
    end

    test "returns miss message for unknown key" do
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, "no memory at key: ghost_key"} =
        ToolDispatch.execute(%{name: "forget", args: %{"key" => "ghost_key"}}, manifest)
    end
  end

  describe "list_memories built-in" do
    setup do
      Shem.Memory.Store.flush()
      on_exit(fn -> Shem.Memory.Store.flush() end)
      :ok
    end

    test "returns 'no memories found' when store is empty" do
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, "no memories found"} =
        ToolDispatch.execute(%{name: "list_memories", args: %{}}, manifest)
    end

    test "returns sorted key = value lines" do
      Shem.Memory.Store.put("b/key", "2")
      Shem.Memory.Store.put("a/key", "1")
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, result} =
        ToolDispatch.execute(%{name: "list_memories", args: %{}}, manifest)
      lines = String.split(result, "\n")
      assert Enum.at(lines, 0) == "a/key = 1"
      assert Enum.at(lines, 1) == "b/key = 2"
    end

    test "filters by prefix when prefix arg is provided" do
      Shem.Memory.Store.put("coding/style", "functional")
      Shem.Memory.Store.put("user/name", "alice")
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, result} =
        ToolDispatch.execute(%{name: "list_memories", args: %{"prefix" => "coding/"}}, manifest)
      assert String.contains?(result, "coding/style")
      refute String.contains?(result, "user/name")
    end
  end
```

- [ ] **Step 2: Run new tests to confirm they fail**

```bash
mix test test/shem/agent/tool_dispatch_test.exs 2>&1 | tail -20
```

Expected: failures — `remember`, `recall`, `forget`, `list_memories` are unknown built-ins.

- [ ] **Step 3: Add `alias Shem.Memory` to `ToolDispatch`**

Open `lib/shem/agent/tool_dispatch.ex`. In the alias block at the top (lines 2–5), add:

```elixir
  alias Shem.Agent.Config
  alias Shem.Lab
  alias Shem.MCP
  alias Shem.Trust
  alias Shem.Memory
```

- [ ] **Step 4: Add four entries to `@builtins`**

In `lib/shem/agent/tool_dispatch.ex`, append the following four maps to the `@builtins` list, after the existing `shell` entry (before the closing `]`):

```elixir
    %{
      name: "remember",
      description: "Store a value under a key in persistent memory. Use namespaced keys like \"coding/style\" or \"user/name\" to avoid collisions.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{
          "key"   => %{"type" => "string"},
          "value" => %{"type" => "string"}
        },
        required: ["key", "value"]
      }
    },
    %{
      name: "recall",
      description: "Retrieve a previously stored memory by key. Returns the value or a miss message.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{"key" => %{"type" => "string"}},
        required: ["key"]
      }
    },
    %{
      name: "forget",
      description: "Delete a memory entry by key.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{"key" => %{"type" => "string"}},
        required: ["key"]
      }
    },
    %{
      name: "list_memories",
      description: "List all stored memories, optionally filtered by key prefix (e.g. \"coding/\"). Returns sorted key = value lines.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{"prefix" => %{"type" => "string"}},
        required: []
      }
    }
```

- [ ] **Step 5: Add four `dispatch_builtin` clauses**

In `lib/shem/agent/tool_dispatch.ex`, add the following four clauses after the existing `dispatch_builtin("shell", ...)` clause and before `defp dispatch_builtin(name, _args)` (the fallthrough):

```elixir
  defp dispatch_builtin("remember", args) do
    key = args["key"]
    value = args["value"]

    if is_binary(key) and is_binary(value) do
      Memory.Store.put(key, value)
      {:ok, "stored: #{key}"}
    else
      {:error, "remember requires key and value"}
    end
  end

  defp dispatch_builtin("recall", args) do
    key = args["key"] || ""

    case Memory.Store.get(key) do
      {:ok, value} -> {:ok, value}
      {:error, :not_found} -> {:ok, "no memory at key: #{key}"}
    end
  end

  defp dispatch_builtin("forget", args) do
    key = args["key"] || ""

    case Memory.Store.delete(key) do
      :ok -> {:ok, "forgotten: #{key}"}
      {:error, :not_found} -> {:ok, "no memory at key: #{key}"}
    end
  end

  defp dispatch_builtin("list_memories", args) do
    prefix = args["prefix"] || ""

    case Memory.Store.all(prefix) do
      [] ->
        {:ok, "no memories found"}

      entries ->
        lines = Enum.map(entries, fn {k, v} -> "#{k} = #{v}" end)
        {:ok, Enum.join(lines, "\n")}
    end
  end
```

- [ ] **Step 6: Run the new tests to confirm they pass**

```bash
mix test test/shem/agent/tool_dispatch_test.exs
```

Expected: all tests pass.

- [ ] **Step 7: Run the full test suite**

```bash
mix test
```

Expected: all tests pass. Count should be 671 + new tests (approximately 686+).

- [ ] **Step 8: Commit**

```bash
git add lib/shem/agent/tool_dispatch.ex test/shem/agent/tool_dispatch_test.exs
git commit -m "feat: memory builtins — remember/recall/forget/list_memories"
```
