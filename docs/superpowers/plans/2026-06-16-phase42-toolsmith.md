# Phase 42 — Toolsmith Self-Evolution Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the self-evolution loop so a general agent can delegate tool authorship to an `elixir_toolsmith` sub-agent, which writes Elixir source + StreamData tests, graduates the tool with a human-readable description, and returns `"graduated: <name>"` — after which the parent agent calls the new tool in the same session.

**Architecture:** Three targeted changes and one new preset. `GraduationGate.run/3` gains a `opts` keyword arg carrying `description` and `schema` stored in `tool.metadata`. The `write_tool` builtin schema and dispatch are extended to thread those fields through. A new `elixir_toolsmith` builtin preset is added with a restricted tool set (`write_tool`, `run_code`), `max_turns: 8`, and a system prompt that teaches models the Shem tool format. `general` and `coder` presets gain one sentence pointing to `spawn_agent(preset: "elixir_toolsmith", ...)` as the way to fill capability gaps.

**Tech Stack:** Elixir, ExUnit, StreamData, OTP — no new dependencies.

---

## File Map

| File | Change |
|---|---|
| `lib/shem/lab/graduation_gate.ex` | `run/3` third arg becomes `opts :: keyword()`; stores `description`/`schema` in `tool.metadata` |
| `test/shem/lab/graduation_gate_test.exs` | Update constraints test to keyword form; add metadata description/schema tests |
| `lib/shem/agent/tool_dispatch.ex` | Extend `write_tool` schema with `description` (required) + `schema` (optional); thread through dispatch |
| `test/shem/agent/tool_dispatch_test.exs` | Add write_tool schema shape test; add description-threaded-to-manifest test |
| `lib/shem/agent/preset.ex` | Add `elixir_toolsmith` entry; update `general`/`coder` system prompts; return `max_turns` from `resolve/1` |
| `lib/shem/agent.ex` | `start_with_preset/3` reads `preset.max_turns` instead of hardcoding 20 |
| `test/shem/agent/preset_test.exs` | Tests for `elixir_toolsmith` resolution, tool restriction, max_turns; update built-in names test |

---

## Task 1: GraduationGate — opts keyword signature + description/schema metadata

**Files:**
- Modify: `lib/shem/lab/graduation_gate.ex`
- Test: `test/shem/lab/graduation_gate_test.exs`

- [ ] **Step 1: Write failing tests**

Add these tests to `test/shem/lab/graduation_gate_test.exs`, inside a new `describe "opts keyword arg"` block after the existing tests:

```elixir
describe "opts keyword arg" do
  test "stores description in tool.metadata" do
    source = """
    defmodule GateDesc1 do
      def run(%{"x" => x}), do: x * 2
    end
    """
    test_src = """
    defmodule GateDesc1Test do
      def run do
        unless GateDesc1.run(%{"x" => 3}) == 6, do: raise "broken"
        :ok
      end
    end
    """
    assert {:ok, tool} = GraduationGate.run(source, test_src,
      description: "Doubles x. Args: x (integer). Returns integer.")
    assert tool.metadata["description"] == "Doubles x. Args: x (integer). Returns integer."
  end

  test "stores schema in tool.metadata" do
    source = """
    defmodule GateDesc2 do
      def run(%{"x" => x}), do: x + 1
    end
    """
    test_src = """
    defmodule GateDesc2Test do
      def run do
        unless GateDesc2.run(%{"x" => 1}) == 2, do: raise "broken"
        :ok
      end
    end
    """
    schema = %{"type" => "object", "properties" => %{"x" => %{"type" => "integer"}}}
    assert {:ok, tool} = GraduationGate.run(source, test_src, schema: schema)
    assert tool.metadata["schema"] == schema
  end

  test "description defaults to empty string when not provided" do
    source = """
    defmodule GateDesc3 do
      def run(_args), do: :ok
    end
    """
    test_src = """
    defmodule GateDesc3Test do
      def run, do: :ok
    end
    """
    assert {:ok, tool} = GraduationGate.run(source, test_src)
    assert tool.metadata["description"] == ""
    assert tool.metadata["schema"] == %{}
  end
end
```

Also update the existing constraints test (line ~82) — change the third arg from a bare list to a keyword:

```elixir
# BEFORE:
assert {:ok, tool} = GraduationGate.run(source, test_source, constraints)

# AFTER:
assert {:ok, tool} = GraduationGate.run(source, test_source, constraints: constraints)
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd /home/philip/Downloads/_project/shem
mix test test/shem/lab/graduation_gate_test.exs --seed 0
```

Expected: the three new `GateDesc` tests fail with `** (FunctionClauseError)` or pattern errors; the existing constraints test fails with `Keyword.get` on a non-keyword list.

- [ ] **Step 3: Implement in `lib/shem/lab/graduation_gate.ex`**

Change the spec annotation and function head:

```elixir
@spec run(String.t(), String.t(), keyword()) ::
        {:ok, Tool.t()}
        | {:error, :compile, String.t()}
        | {:error, :gate, any()}
        | {:error, :timeout}
def run(source, test_source, opts \\ []) do
  description = Keyword.get(opts, :description, "")
  schema      = Keyword.get(opts, :schema, %{})
  constraints = Keyword.get(opts, :constraints, [])

  combined = source <> "\n" <> test_source
```

Then update the `%Tool{}` construction (currently around line 27) to include the new metadata fields:

```elixir
tool = %Tool{
  id: id,
  name: module |> Atom.to_string() |> String.split(".") |> List.last(),
  module: module,
  source: source,
  test_source: test_source,
  constraints: constraints,
  graduated_at: DateTime.utc_now(),
  metadata: %{
    property_tested: property?,
    "description"   => description,
    "schema"        => schema
  }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
mix test test/shem/lab/graduation_gate_test.exs --seed 0
```

Expected: all graduation_gate tests pass.

- [ ] **Step 5: Run full suite to catch regressions**

```bash
mix test --seed 0
```

Expected: same pass count as before (1028+) with no new failures.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/lab/graduation_gate.ex test/shem/lab/graduation_gate_test.exs
git commit -m "feat: GraduationGate opts keyword arg — description and schema stored in tool.metadata"
```

---

## Task 2: `write_tool` builtin — extend schema and thread description/schema through dispatch

**Files:**
- Modify: `lib/shem/agent/tool_dispatch.ex`
- Test: `test/shem/agent/tool_dispatch_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/shem/agent/tool_dispatch_test.exs`, in the existing `describe "build_manifest/1"` block:

```elixir
test "write_tool schema includes description (required) and schema (optional)" do
  manifest = ToolDispatch.build_manifest(@config)
  write_tool = Enum.find(manifest, &(&1.name == "write_tool"))
  assert write_tool != nil
  props = write_tool.schema.properties
  assert Map.has_key?(props, "description")
  assert Map.has_key?(props, "schema")
  assert "description" in write_tool.schema.required
  refute "schema" in write_tool.schema.required
end
```

Add a new `describe "execute/3 — write_tool"` block:

```elixir
describe "execute/3 — write_tool" do
  test "description is stored in graduated tool metadata" do
    source = """
    defmodule DispatchDescTool do
      def run(%{"n" => n}), do: n + 1
    end
    """
    test_src = """
    defmodule DispatchDescToolTest do
      def run do
        unless DispatchDescTool.run(%{"n" => 1}) == 2, do: raise "broken"
        :ok
      end
    end
    """
    manifest = ToolDispatch.build_manifest(@config)
    args = %{
      "source" => source,
      "test_source" => test_src,
      "description" => "Increments n by 1. Args: n (integer). Returns integer."
    }
    assert {:ok, "graduated: DispatchDescTool"} =
             ToolDispatch.execute(%{name: "write_tool", args: args}, manifest)

    {:ok, tool} = Shem.Lab.Registry.lookup("dispatch_desc_tool")
    assert tool.metadata["description"] == "Increments n by 1. Args: n (integer). Returns integer."
  end

  test "graduated tool appears in manifest with its description" do
    source = """
    defmodule DispatchManifestTool do
      def run(_args), do: :manifest_ok
    end
    """
    test_src = """
    defmodule DispatchManifestToolTest do
      def run, do: :ok
    end
    """
    manifest = ToolDispatch.build_manifest(@config)
    args = %{
      "source"      => source,
      "test_source" => test_src,
      "description" => "Always returns :manifest_ok. No args required."
    }
    assert {:ok, _} = ToolDispatch.execute(%{name: "write_tool", args: args}, manifest)

    fresh_manifest = ToolDispatch.build_manifest(@config)
    entry = Enum.find(fresh_manifest, &(&1.name == "DispatchManifestTool"))
    assert entry != nil
    assert entry.description == "Always returns :manifest_ok. No args required."
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/shem/agent/tool_dispatch_test.exs --seed 0
```

Expected: the three new tests fail — schema test fails because `description` key is absent; execute tests fail because description is not threaded.

- [ ] **Step 3: Implement in `lib/shem/agent/tool_dispatch.ex`**

Update the `write_tool` entry in `@builtins` (currently around line 33):

```elixir
%{
  name: "write_tool",
  description: "Graduate a new Elixir tool into the Lab. Requires description of what the tool does.",
  source: :builtin,
  trust: :builtin,
  schema: %{
    type: "object",
    properties: %{
      "source"      => %{"type" => "string"},
      "test_source" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "schema"      => %{"type" => "object"}
    },
    required: ["source", "test_source", "description"]
  }
},
```

Update `dispatch_builtin("write_tool", args)` (currently around line 267):

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

- [ ] **Step 4: Run tests to confirm they pass**

```bash
mix test test/shem/agent/tool_dispatch_test.exs --seed 0
```

Expected: all tool_dispatch tests pass.

- [ ] **Step 5: Run full suite**

```bash
mix test --seed 0
```

Expected: all passing (same count + 3 new).

- [ ] **Step 6: Commit**

```bash
git add lib/shem/agent/tool_dispatch.ex test/shem/agent/tool_dispatch_test.exs
git commit -m "feat: write_tool builtin gains description + schema fields, threaded to GraduationGate"
```

---

## Task 3: `elixir_toolsmith` preset + max_turns plumbing

**Files:**
- Modify: `lib/shem/agent/preset.ex`
- Modify: `lib/shem/agent.ex`
- Test: `test/shem/agent/preset_test.exs`

- [ ] **Step 1: Write failing tests**

Add a new `describe "elixir_toolsmith preset"` block to `test/shem/agent/preset_test.exs`:

```elixir
describe "elixir_toolsmith preset" do
  test "resolves successfully" do
    assert {:ok, preset} = Preset.resolve("elixir_toolsmith")
    assert is_binary(preset.system_prompt)
  end

  test "tools restricted to write_tool and run_code" do
    assert {:ok, preset} = Preset.resolve("elixir_toolsmith")
    assert is_list(preset.tools)
    assert "write_tool" in preset.tools
    assert "run_code" in preset.tools
    refute "shell" in preset.tools
    refute "spawn_agent" in preset.tools
    refute "read_file" in preset.tools
  end

  test "max_turns is 8" do
    assert {:ok, preset} = Preset.resolve("elixir_toolsmith")
    assert preset.max_turns == 8
  end

  test "system prompt teaches write_tool calling convention" do
    assert {:ok, preset} = Preset.resolve("elixir_toolsmith")
    assert preset.system_prompt =~ "write_tool"
    assert preset.system_prompt =~ "description"
    assert preset.system_prompt =~ "graduated:"
  end
end
```

Also update the existing `"includes all six built-in presets"` test to include `elixir_toolsmith`:

```elixir
test "includes all seven built-in presets" do
  names = Preset.all() |> Enum.map(& &1.name)
  for name <- ~w[general coder researcher writer security explorer elixir_toolsmith] do
    assert name in names
  end
end
```

And add a test that `general` and `coder` mention the toolsmith:

```elixir
test "general preset system prompt mentions elixir_toolsmith" do
  assert {:ok, preset} = Preset.resolve("general")
  assert preset.system_prompt =~ "elixir_toolsmith"
end

test "coder preset system prompt mentions elixir_toolsmith" do
  assert {:ok, preset} = Preset.resolve("coder")
  assert preset.system_prompt =~ "elixir_toolsmith"
end
```

Add a test that non-toolsmith presets return default max_turns (20) when max_turns not set:

```elixir
test "general preset max_turns defaults to 20" do
  assert {:ok, preset} = Preset.resolve("general")
  assert preset.max_turns == 20
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/shem/agent/preset_test.exs --seed 0
```

Expected: `elixir_toolsmith` tests fail with `{:error, :not_found}`; max_turns tests fail with `KeyError`.

- [ ] **Step 3: Implement in `lib/shem/agent/preset.ex`**

Add `elixir_toolsmith` entry to `@builtin_presets`. Insert it after the `explorer` entry (before the closing `]`):

```elixir
%{
  name: "elixir_toolsmith",
  system_prompt: """
  You are an Elixir tool smith. Your sole job is to write, test, and graduate one Elixir tool
  into the Shem Lab based on the task description you receive.

  ## Tool format

  Every tool is an Elixir module with a single public function `run/1` that accepts a plain map
  with string keys and returns any value:

      defmodule MyTool do
        def run(%{"key" => value}) do
          # implementation
        end
      end

  - Module name must be CamelCase and unique. Prefer descriptive names: `LevenshteinDistance`,
    `WordFrequency`, `CsvParser`.
  - `run/1` must handle the args map pattern-matched on the exact keys the caller will pass.
  - No external dependencies. Use only Elixir standard library and `:erlang` built-ins.
  - No I/O side effects inside `run/1`. Pure functions only.

  ## Test format

  Tests use ExUnit + StreamData property testing:

      defmodule MyToolTest do
        use ExUnit.Case
        use ExUnitProperties

        property "describes the invariant" do
          check all input <- StreamData.string(:alphanumeric, min_length: 1) do
            result = MyTool.run(%{"key" => input})
            assert <invariant>
          end
        end

        test "concrete example" do
          assert MyTool.run(%{"key" => "value"}) == expected
        end
      end

  - Always include at least one StreamData `property` block. This earns the tool a high trust score.
  - Include at least one concrete `test` block with a known input/output pair.
  - The test module must be named `<ToolModule>Test`.

  ## Graduating the tool

  When your implementation is ready, call `write_tool` with:
  - `source`: the complete module source
  - `test_source`: the complete test module source
  - `description`: one sentence describing what the tool does, what args it takes, and what it returns.
    Example: "Computes Levenshtein edit distance between two strings. Args: a (string), b (string). Returns integer."
  - `schema` (optional): a JSON Schema object describing the args map, e.g.
    `{"type": "object", "properties": {"a": {"type": "string"}, "b": {"type": "string"}}, "required": ["a", "b"]}`

  ## On compile or test failure

  If `write_tool` returns a compile error or test failure, read the error carefully, fix the
  implementation, and call `write_tool` again. Do not give up after one attempt.

  ## Response to your caller

  After a successful graduation, respond with exactly:
      graduated: <tool_name>

  If you cannot graduate the tool after several attempts, respond with:
      failed: <one sentence reason>
  """,
  tools: ["write_tool", "run_code"],
  max_turns: 8
},
```

Update the `general` preset system prompt — append one sentence before the closing `"""`:

```elixir
system_prompt: """
You are Shem — a helpful, general-purpose AI assistant running on the user's machine.
You can help with coding, research, writing, security audits, filesystem exploration, and general questions.
When asked what you can do, explain these capabilities. Mention that `/preset coder`, `/preset researcher`, `/preset writer`, `/preset security`, or `/preset explorer` switches to a specialist mode.
You have access to the user's filesystem and shell via the tools listed below. Use them when they help.
Be concise and direct. If you don't know something, say so.
When a task requires a capability not available in list_tools, you may create it by calling spawn_agent(preset: "elixir_toolsmith", task: "write a tool that <description of what it should do, what args it takes, what it returns>").
""",
```

Update the `coder` preset system prompt — append one sentence before the closing `"""`:

```elixir
system_prompt: """
You are an expert software engineer. You help with reading, writing, refactoring, and debugging code across all common languages and frameworks.
You have access to the user's working directory and can read and modify files directly.
Before making changes: read the relevant files to understand context and conventions.
Prefer small, targeted edits. Follow existing code style. After changes, verify them — run tests if available.
Summarise what you changed and why when finished.
When a task requires a capability not available in list_tools, you may create it by calling spawn_agent(preset: "elixir_toolsmith", task: "write a tool that <description of what it should do, what args it takes, what it returns>").
""",
```

Update `resolve/1` to return `max_turns` (change `Map.take` to include the key):

```elixir
def resolve(name) do
  case find_in_static(name) do
    {:ok, preset} ->
      {:ok, Map.take(preset, [:system_prompt, :tools, :max_turns])
            |> Map.put_new(:max_turns, 20)}

    :error ->
      try do
        case Shem.Agent.PresetStore.get(name) do
          {:ok, preset} ->
            {:ok, Map.take(preset, [:system_prompt, :tools, :max_turns])
                  |> Map.put_new(:max_turns, 20)}
          {:error, :not_found} -> {:error, :not_found}
        end
      catch
        :exit, _ -> {:error, :not_found}
      end
  end
end
```

- [ ] **Step 4: Update `lib/shem/agent.ex` to use preset.max_turns**

In `start_with_preset/3`, change the hardcoded `max_turns: 20` to read from the preset:

```elixir
def start_with_preset(preset_name, task, opts \\ []) do
  with {:ok, preset} <- Shem.Agent.Preset.resolve(preset_name) do
    config = %Config{
      task: task,
      system_prompt: preset.system_prompt,
      tools: if(preset.tools == :all, do: [], else: preset.tools),
      max_turns: Map.get(preset, :max_turns, 20),
      spawn_depth: Keyword.get(opts, :spawn_depth, 0),
      conversational: Keyword.get(opts, :conversational, false),
      project_context: Keyword.get(opts, :project_context, Shem.Context.Project.detect()),
      placement: Keyword.get(opts, :placement, :any)
    }
    start(config)
  end
end
```

- [ ] **Step 5: Run preset tests**

```bash
mix test test/shem/agent/preset_test.exs --seed 0
```

Expected: all preset tests pass including the new `elixir_toolsmith` tests and the updated built-in names test.

- [ ] **Step 6: Run full suite**

```bash
mix test --seed 0
```

Expected: all passing (same count + new preset tests).

- [ ] **Step 7: Commit**

```bash
git add lib/shem/agent/preset.ex lib/shem/agent.ex test/shem/agent/preset_test.exs
git commit -m "feat: elixir_toolsmith preset — write_tool+run_code only, max_turns: 8, plumbed through start_with_preset"
```

---

## Self-Review Checklist

**Spec coverage:**

| Spec requirement | Task covering it |
|---|---|
| `write_tool` gains `description` (required) + `schema` (optional) | Task 2 schema change |
| `description`/`schema` passed to `GraduationGate.run/3` via opts | Task 1 + Task 2 dispatch |
| Stored in `tool.metadata` as string-keyed entries | Task 1 implementation |
| `build_manifest` already reads `metadata["description"]` — no change needed | Verified: line 190 of tool_dispatch.ex |
| `elixir_toolsmith` preset resolves via `Preset.resolve/1` | Task 3 |
| `elixir_toolsmith` restricted to `write_tool` + `run_code` | Task 3 |
| `max_turns: 8` on `elixir_toolsmith` | Task 3 |
| `list_tools` always injected regardless of allow-list | Verified: existing code in `build_manifest/1` |
| `general` + `coder` system prompts mention `elixir_toolsmith` | Task 3 |
| EventLog trail is full (no new plumbing needed) | Verified: `spawn_agent` dispatch already emits tool events |

**No placeholders found.**

**Type consistency:** `GraduationGate.run/3` opts keyword is used consistently — Task 1 defines it, Task 2 calls with `description:` and `schema:` keyword args.
