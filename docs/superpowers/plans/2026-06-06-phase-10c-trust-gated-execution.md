# Phase 10c: Trust-Gated Execution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Block agents from invoking Lab tools with a `:low` trust band; allow all other bands including `:unrated`.

**Architecture:** `ToolDispatch.execute/2` is refactored to pattern-match the full manifest entry instead of just the source, adding a trust check before dispatching Lab tools. The gate is toggled by `Application.get_env(:shem, :trust_gate_enabled, true)`. Builtin and MCP tools are never gated. Config default is `true`; test env overrides to `false` so existing tests are unaffected.

**Tech Stack:** Elixir/OTP, ExUnit

---

## File Map

**Modify:**
- `config/config.exs` — set `trust_gate_enabled: true` as base default
- `config/test.exs` — override `trust_gate_enabled: false` so existing tests pass
- `lib/shem/agent/tool_dispatch.ex` — refactor `execute/2`, remove `find_source/2`, add `gate_blocks?/1`
- `test/shem/agent/tool_dispatch_test.exs` — fix existing Lab dispatch test (missing `trust:` key), add trust gate describe block

---

### Task 1: Config

**Files:**
- Modify: `config/config.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Add base default to `config/config.exs`**

Replace the entire file with:

```elixir
import Config

config :shem, trust_gate_enabled: true

import_config "#{config_env()}.exs"
```

- [ ] **Step 2: Add test override to `config/test.exs`**

Add this line at the end of `config/test.exs`:

```elixir
config :shem, trust_gate_enabled: false
```

- [ ] **Step 3: Run full suite to confirm no regressions**

```bash
cd /home/philip/Downloads/_project/shem
mix test 2>&1 | tail -5
```

Expected: all tests pass (no behavior change yet).

- [ ] **Step 4: Commit**

```bash
git add config/config.exs config/test.exs
git commit -m "config: add trust_gate_enabled flag (default true, false in test)"
```

---

### Task 2: Trust gate in `ToolDispatch`

**Files:**
- Modify: `lib/shem/agent/tool_dispatch.ex`
- Modify: `test/shem/agent/tool_dispatch_test.exs`

- [ ] **Step 1: Write failing tests**

Add the following `describe` block at the end of `test/shem/agent/tool_dispatch_test.exs`, before the final `end`:

```elixir
describe "execute/2 — trust gate" do
  setup do
    source = """
    defmodule TrustGateTool do
      def run(_args), do: :gated
    end
    """
    test_src = """
    defmodule TrustGateToolTest do
      def run, do: :ok
    end
    """
    {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
    {:ok, tool: tool}
  end

  test "low-trust tool is blocked when gate enabled", %{tool: tool} do
    Application.put_env(:shem, :trust_gate_enabled, true)
    on_exit(fn -> Application.put_env(:shem, :trust_gate_enabled, false) end)

    manifest = [%{name: tool.name, description: "", source: {:lab, tool.id}, trust: :low}]
    assert {:error, "tool blocked (trust: low)"} =
             ToolDispatch.execute(%{tool: tool.name, args: %{}}, manifest)
  end

  test "low-trust tool is allowed when gate disabled", %{tool: tool} do
    manifest = [%{name: tool.name, description: "", source: {:lab, tool.id}, trust: :low}]
    assert {:ok, _} = ToolDispatch.execute(%{tool: tool.name, args: %{}}, manifest)
  end

  test "unrated tool is allowed when gate enabled", %{tool: tool} do
    Application.put_env(:shem, :trust_gate_enabled, true)
    on_exit(fn -> Application.put_env(:shem, :trust_gate_enabled, false) end)

    manifest = [%{name: tool.name, description: "", source: {:lab, tool.id}, trust: :unrated}]
    assert {:ok, _} = ToolDispatch.execute(%{tool: tool.name, args: %{}}, manifest)
  end

  test "medium-trust tool is allowed when gate enabled", %{tool: tool} do
    Application.put_env(:shem, :trust_gate_enabled, true)
    on_exit(fn -> Application.put_env(:shem, :trust_gate_enabled, false) end)

    manifest = [%{name: tool.name, description: "", source: {:lab, tool.id}, trust: :medium}]
    assert {:ok, _} = ToolDispatch.execute(%{tool: tool.name, args: %{}}, manifest)
  end

  test "high-trust tool is allowed when gate enabled", %{tool: tool} do
    Application.put_env(:shem, :trust_gate_enabled, true)
    on_exit(fn -> Application.put_env(:shem, :trust_gate_enabled, false) end)

    manifest = [%{name: tool.name, description: "", source: {:lab, tool.id}, trust: :high}]
    assert {:ok, _} = ToolDispatch.execute(%{tool: tool.name, args: %{}}, manifest)
  end

  test "builtin is never blocked regardless of gate", %{tool: _tool} do
    Application.put_env(:shem, :trust_gate_enabled, true)
    on_exit(fn -> Application.put_env(:shem, :trust_gate_enabled, false) end)

    path = Path.join(System.tmp_dir!(), "shem_gate_#{System.unique_integer([:positive])}.txt")
    File.write!(path, "x")
    on_exit(fn -> File.rm(path) end)

    manifest = [%{name: "read_file", description: "read", source: :builtin, trust: :builtin}]
    assert {:ok, "x"} =
             ToolDispatch.execute(%{tool: "read_file", args: %{"path" => path}}, manifest)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/shem/agent/tool_dispatch_test.exs --seed 0 2>&1 | tail -15
```

Expected: failures on the new trust gate tests — `execute/2` currently routes Lab tools without any trust check, so the "blocked" assertion will fail.

- [ ] **Step 3: Fix existing Lab dispatch test**

The existing test at line ~219 builds a manifest entry without a `trust:` key. After the refactor in the next step, `execute/2` will pattern-match on `trust:` for Lab entries — so this test must be updated now.

Find this block in `test/shem/agent/tool_dispatch_test.exs`:

```elixir
  describe "execute/2 — Lab tool dispatch" do
    test "routes to a graduated tool and returns its result" do
      source = """
      defmodule LabDispatchTool1 do
        def run(args), do: Map.get(args, "x", 0) * 2
      end
      """
      test_src = """
      defmodule LabDispatchTool1Test do
        def run, do: :ok
      end
      """
      {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
      manifest = [%{name: tool.name, description: "", source: {:lab, tool.id}}]
      assert {:ok, "2"} =
               ToolDispatch.execute(%{tool: tool.name, args: %{"x" => 1}}, manifest)
    end
  end
```

Replace it with:

```elixir
  describe "execute/2 — Lab tool dispatch" do
    test "routes to a graduated tool and returns its result" do
      source = """
      defmodule LabDispatchTool1 do
        def run(args), do: Map.get(args, "x", 0) * 2
      end
      """
      test_src = """
      defmodule LabDispatchTool1Test do
        def run, do: :ok
      end
      """
      {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
      manifest = [%{name: tool.name, description: "", source: {:lab, tool.id}, trust: :unrated}]
      assert {:ok, "2"} =
               ToolDispatch.execute(%{tool: tool.name, args: %{"x" => 1}}, manifest)
    end
  end
```

- [ ] **Step 4: Implement the gate in `lib/shem/agent/tool_dispatch.ex`**

Replace the existing `execute/2` (the second clause, lines ~124–131) and `find_source/2` (lines ~133–138) with:

```elixir
  def execute(%{tool: name, args: args}, manifest) do
    case Enum.find(manifest, &(&1.name == name)) do
      nil ->
        {:error, "unknown tool: #{name}"}

      %{source: :builtin} ->
        dispatch_builtin(name, args)

      %{source: {:mcp, server}} ->
        dispatch_mcp(server, name, args)

      %{source: {:lab, id}, trust: trust} ->
        if gate_blocks?(trust),
          do: {:error, "tool blocked (trust: #{trust})"},
          else: dispatch_lab(id, args)
    end
  end
```

Add this private helper directly above `defp dispatch_builtin`:

```elixir
  defp gate_blocks?(:low), do: Application.get_env(:shem, :trust_gate_enabled, true)
  defp gate_blocks?(_), do: false
```

Delete the now-unused `find_source/2`:

```elixir
  defp find_source(name, manifest) do
    case Enum.find(manifest, &(&1.name == name)) do
      %{source: source} -> source
      nil -> nil
    end
  end
```

- [ ] **Step 5: Run trust gate tests to verify they pass**

```bash
mix test test/shem/agent/tool_dispatch_test.exs --seed 0 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 6: Run full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/shem/agent/tool_dispatch.ex test/shem/agent/tool_dispatch_test.exs
git commit -m "feat: trust-gated execution — block :low Lab tools in ToolDispatch"
```

---

## Self-Review

**Spec coverage:**
- ✅ `:low` trust blocked when gate enabled — Task 2 test "low-trust tool is blocked when gate enabled"
- ✅ `:low` trust allowed when gate disabled — Task 2 test "low-trust tool is allowed when gate disabled"
- ✅ `:unrated` always allowed — Task 2 test "unrated tool is allowed when gate enabled"
- ✅ `:medium` / `:high` always allowed — Task 2 tests for each band
- ✅ Builtins never blocked — Task 2 test "builtin is never blocked regardless of gate"
- ✅ MCP tools never gated — covered by pattern match; no path through `gate_blocks?/1`
- ✅ `trust_gate_enabled: true` default — `gate_blocks?/1` default arg + `config/config.exs` Task 1
- ✅ `trust_gate_enabled: false` in test — `config/test.exs` Task 1
- ✅ Error message format `"tool blocked (trust: low)"` — matches spec and test assertion
- ✅ `find_source/2` removed — Task 2 Step 4
- ✅ Manifest enrichment untouched — no changes to `build_manifest/1`

**Placeholder scan:** None.

**Type consistency:** `gate_blocks?/1` defined and used in same task. Trust band atoms (`:low`, `:unrated`, `:medium`, `:high`, `:builtin`) match Phase 10b definitions throughout.
