# Tool Allow-List Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Config.tools` the single enforced allow-list for builtins and Lab tools in `build_manifest/1`, matching the existing MCP filtering behavior.

**Architecture:** `build_manifest/1` filters all three tool categories (builtins, lab, MCP) against `Config.tools`. `tools: []` means allow-all. `list_tools` is always injected regardless — it's a pure meta-capability. No changes to `execute/2`, `Server`, or `Turn`.

**Tech Stack:** Elixir, ExUnit

---

## File Map

- Modify: `lib/shem/agent/tool_dispatch.ex` — filter builtins and lab tools in `build_manifest/1`
- Modify: `test/shem/agent/tool_dispatch_test.exs` — two new tests for allow-list filtering

---

### Task 1: Test — allow-list filters builtins

**Files:**
- Modify: `test/shem/agent/tool_dispatch_test.exs`

- [ ] **Step 1: Write the two failing tests**

Add these two test cases inside the existing `describe "build_manifest/1"` block in `test/shem/agent/tool_dispatch_test.exs`:

```elixir
test "allow-list filters builtins to only listed names (plus list_tools always present)" do
  config = %Config{task: "t", system_prompt: "s", tools: ["read_file", "list_dir"]}
  manifest = ToolDispatch.build_manifest(config)
  names = Enum.map(manifest, & &1.name)
  assert "read_file" in names
  assert "list_dir" in names
  assert "list_tools" in names
  refute "write_file" in names
  refute "shell" in names
  refute "run_code" in names
  refute "write_tool" in names
end

test "allow-list excludes Lab tools whose names are not listed" do
  source = """
  defmodule AllowListLabTool do
    def run(_args), do: :ok
  end
  """
  test_src = """
  defmodule AllowListLabToolTest do
    def run, do: :ok
  end
  """
  {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)

  config_excluded = %Config{task: "t", system_prompt: "s", tools: ["read_file"]}
  manifest_excluded = ToolDispatch.build_manifest(config_excluded)
  refute Enum.any?(manifest_excluded, &(&1.source == {:lab, tool.id}))

  config_included = %Config{task: "t", system_prompt: "s", tools: [tool.name]}
  manifest_included = ToolDispatch.build_manifest(config_included)
  assert Enum.any?(manifest_included, &(&1.source == {:lab, tool.id}))
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/philip/Downloads/_project/shem
mix test test/shem/agent/tool_dispatch_test.exs --seed 0 2>&1 | tail -20
```

Expected: 2 failures. The first test fails because `write_file` and others are still in the manifest. The second fails because the Lab tool is still included regardless of the allow-list.

---

### Task 2: Implement — filter builtins and lab tools in `build_manifest/1`

**Files:**
- Modify: `lib/shem/agent/tool_dispatch.ex`

- [ ] **Step 1: Update `build_manifest/1`**

Replace the current `build_manifest/1` function body (lines 48–81 in `tool_dispatch.ex`) with:

```elixir
@spec build_manifest(Config.t()) :: [map()]
def build_manifest(%Config{tools: allowed_tools}) do
  builtins =
    @builtins
    |> then(fn bs ->
      if allowed_tools == [],
        do: bs,
        else: Enum.filter(bs, &(&1.name in allowed_tools))
    end)
    |> then(fn bs ->
      if Enum.any?(bs, &(&1.name == "list_tools")),
        do: bs,
        else: [Enum.find(@builtins, &(&1.name == "list_tools")) | bs]
    end)

  lab_tools =
    Lab.Registry.all()
    |> then(fn tools ->
      if allowed_tools == [],
        do: tools,
        else: Enum.filter(tools, &(&1.name in allowed_tools))
    end)
    |> Enum.map(fn tool ->
      %{
        name: tool.name,
        description: Map.get(tool.metadata, "description", "graduated tool: #{tool.name}"),
        source: {:lab, tool.id}
      }
    end)

  mcp_tools =
    MCP.Client.connected_servers()
    |> Enum.filter(&(&1.status == :ready))
    |> Enum.flat_map(fn %{name: server} ->
      case MCP.Client.list_tools(server) do
        {:ok, tools} ->
          tools
          |> then(fn ts ->
            if allowed_tools == [],
              do: ts,
              else: Enum.filter(ts, &(&1["name"] in allowed_tools))
          end)
          |> Enum.map(fn t ->
            %{name: t["name"], description: t["description"] || "", source: {:mcp, server}}
          end)

        _ ->
          []
      end
    end)

  builtins ++ lab_tools ++ mcp_tools
end
```

- [ ] **Step 2: Run the new tests to verify they pass**

```bash
mix test test/shem/agent/tool_dispatch_test.exs --seed 0 2>&1 | tail -20
```

Expected: all tests in this file pass, including the two new ones.

- [ ] **Step 3: Run the full suite to check for regressions**

```bash
mix test 2>&1 | tail -10
```

Expected: all tests pass (currently 377; count may be 379 after new tests).

- [ ] **Step 4: Commit**

```bash
git add lib/shem/agent/tool_dispatch.ex test/shem/agent/tool_dispatch_test.exs
git commit -m "feat: enforce Config.tools allow-list for builtins and Lab tools in build_manifest"
```

---

## Self-Review

**Spec coverage:**
- ✅ `build_manifest/1` filters builtins against allow-list
- ✅ `build_manifest/1` filters lab tools against allow-list
- ✅ MCP filtering unchanged
- ✅ `list_tools` always implicitly present
- ✅ `tools: []` = allow-all preserved
- ✅ Two new tests added
- ✅ Existing tests unaffected (`@config` uses `tools: []`)
- ✅ `execute/2`, `Server`, `Turn` untouched

**Placeholder scan:** None found.

**Type consistency:** `Config.tools` is `[String.t()]` throughout; `tool.name` and `&1.name` are both strings; `in` operator works correctly.
