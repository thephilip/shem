# Phase 42 — Toolsmith Self-Evolution Loop Design Spec
_2026-06-15_

## Problem

The self-evolution primitive (`write_tool` / `GraduationGate`) exists but is unusable in practice:

1. Graduated tools carry no description — they appear in the manifest as `"graduated tool: <name>"`, giving future agents no basis for calling them.
2. No agent preset knows *how* to write a Shem tool — the format (module conventions, `run/1`, StreamData tests) is undocumented from any model's perspective.
3. The `write_tool` schema has no `description` or `schema` fields, so there is nowhere to store what the tool does.

The result: the loop exists in code but cannot close in practice with a real LLM.

## Goal

Close the self-evolution loop end-to-end with real LLM inference:

- A general agent, given a task that requires a missing tool, delegates tool authorship to an `elixir_toolsmith` sub-agent.
- The toolsmith writes Elixir source, StreamData property tests, and a description; calls `write_tool`; the graduation gate validates and registers the tool.
- The parent agent calls the newly graduated tool and completes its task.
- The full trail is visible in the EventLog and time-travelable.

## Scope

- Elixir tools only. The `<language>_toolsmith` naming convention is established now; `python_toolsmith`, `rust_toolsmith` etc. are future phases.
- No polyglot GraduationGate changes — language routing and non-Elixir executor backends are deferred.
- Model-agnostic: the toolsmith preset works with any OpenAI-compatible model; nothing is tuned for qwen3 specifically.

## Architecture

### 1. `write_tool` Extension

**Schema change** — two new fields added to the `write_tool` builtin's JSON schema:

```elixir
%{
  name: "write_tool",
  description: "Graduate a new Elixir tool into the Lab.",
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
}
```

`description` is required. `schema` is optional (defaults to `%{}`).

**Dispatch change** — `dispatch_builtin("write_tool", args)` passes description and schema into `GraduationGate.run/3` via the existing `constraints` / metadata path:

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

**GraduationGate change** — `run/3` third argument changes from `constraints :: [String.t()]` to `opts :: keyword()`. The tool struct is built with description and schema in metadata:

```elixir
def run(source, test_source, opts \\ []) do
  # ... executor runs tests as before ...
  tool = %Tool{
    id: id,
    name: ...,
    module: module,
    source: source,
    test_source: test_source,
    constraints: Keyword.get(opts, :constraints, []),
    graduated_at: DateTime.utc_now(),
    metadata: %{
      property_tested: property?,
      "description" => Keyword.get(opts, :description, ""),
      "schema"      => Keyword.get(opts, :schema, %{})
    }
  }
```

The tool manifest already reads `metadata["description"]` — no further changes needed there.

**Return value** — `"graduated: <name>"` on success (unchanged). The calling agent receives this string from `spawn_agent`.

### 2. `elixir_toolsmith` Preset

A new entry in `@builtin_presets` in `lib/shem/agent/preset.ex`:

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
}
```

`max_turns: 8` gives the toolsmith up to 4 write/retry cycles while preventing runaway loops.
Tools restricted to `write_tool` and `run_code` only — the toolsmith cannot spawn sub-agents,
touch files, or run shell commands.

### 3. General / Coder Preset Update

Both `general` and `coder` presets gain one sentence appended to their system prompts:

```
When a task requires a capability not available in list_tools, you may create it by calling
spawn_agent(preset: "elixir_toolsmith", task: "write a tool that <description of what it should do, what args it takes, what it returns>").
```

### 4. Data Flow

```
User task → general agent
  → list_tools (sees no matching tool)
  → spawn_agent(preset: "elixir_toolsmith", task: "<spec>")
      → toolsmith calls write_tool(source, test_source, description, schema?)
          → GraduationGate: compile → run tests → register in Lab.Registry
          ← {:ok, tool} / {:error, ...}
      ← "graduated: <name>" or retry loop
  ← "graduated: <name>"
  → list_tools (or trusts the return) → sees <name> in manifest with description
  → <name>(%{"arg" => value})
  ← result
→ final answer to user
```

### 5. EventLog Trail

```
:agent_turn_started        ← parent agent
:agent_thinking            ← parent reasoning (if model produces it)
:agent_tool_called         spawn_agent(preset: "elixir_toolsmith", ...)
  :agent_turn_started      ← toolsmith sub-agent
  :agent_thinking          ← toolsmith reasoning
  :agent_tool_called       write_tool(source, test_source, description)
  :agent_turn_completed
:agent_tool_result         "graduated: <name>"
:agent_tool_called         <name>(args)
:agent_tool_result         "<result>"
:agent_turn_completed      ← parent agent
```

Full chain is auditable and time-travelable. Nothing is hidden.

### 6. Error Handling

| Failure | Toolsmith behaviour | Parent agent sees |
|---------|--------------------|--------------------|
| Compile error | Reads error, fixes source, retries | Transparent (inside spawn_agent) |
| Property test fails | Reads failure, fixes logic or tests, retries | Transparent |
| Executor timeout | `write_tool` returns `"graduation timed out"` | `spawn_agent` returns `"failed: timed out"` |
| `max_turns` exhausted | Sub-agent returns its last message | `spawn_agent` returns whatever the toolsmith last said |
| Parent gets `"failed: ..."` | Parent can report to user or simplify the tool spec and retry | User-visible |

## Testing

- **Unit**: `write_tool` dispatch accepts and threads `description` + `schema` through to `GraduationGate`
- **Unit**: `GraduationGate.run/3` stores description and schema in `tool.metadata`
- **Unit**: `Lab.Registry.all()` surfaces tools with metadata description
- **Unit**: tool manifest entry has correct description from metadata
- **Unit**: `elixir_toolsmith` preset resolves via `Preset.resolve/1`
- **Unit**: toolsmith preset allows only `write_tool` and `run_code` tools
- **Manual / smoke**: run a general agent with a task requiring a missing tool; verify graduation + invocation end-to-end with real LM Studio inference

## Out of Scope

- `python_toolsmith`, `rust_toolsmith` — future phases; naming convention reserved
- Polyglot GraduationGate (language routing, non-Elixir executors) — future phase
- Automatic tool-gap detection (agent proactively noticing it needs a tool without being told) — future
- TUI panel for graduated tools — future
- Schema validation of tool args at call time — future
