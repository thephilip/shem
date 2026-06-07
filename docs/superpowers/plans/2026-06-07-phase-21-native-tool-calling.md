# Phase 21 — Native Tool Calling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace text-based tool invocation (regex-scanned JSON in LLM prose) with native tool calling across all four transports.

**Architecture:** Extend `Request` with `tools: [tool_schema()] | nil` and `Response` with `tool_calls: [tool_call()] | nil`; add inline JSON schemas to `ToolDispatch` builtins; update `Agent.Turn` to populate `request.tools`, drop the text tool header from messages, check `response.tool_calls` in `step/4`; update all four transports to inject the `tools` array and decode structured tool calls; update `Agent.Server` to build history entries with `tool_calls`/`tool_call_id` fields.

**Tech Stack:** Elixir/OTP, ExUnit. No new dependencies.

---

## File Map

| File | Action |
|---|---|
| `lib/shem/llm/request.ex` | Modify — add `tools` field and `tool_schema()` type |
| `lib/shem/llm/response.ex` | Modify — add `tool_calls` field, `tool_call()` type; drop `content` from `@enforce_keys` |
| `lib/shem/agent/tool_dispatch.ex` | Modify — add `schema` to each builtin; permissive fallback for Lab/MCP; rename `:tool` → `:name` in `execute/2` |
| `lib/shem/agent/turn.ex` | Modify — `build_request/4` passes tools; `build_messages/1` (arity drops to 1) drops tool header and handles new history shapes; `parse_response/1` returns `%{id: nil, name, args}`; `step/4` checks `response.tool_calls` first |
| `lib/shem/llm/middleware/openai_transport.ex` | Modify — inject tools array; format new history shapes; decode `tool_calls` from response |
| `lib/shem/llm/middleware/anthropic_transport.ex` | Modify — inject tools with `input_schema`; format content-block messages; decode `tool_use` blocks |
| `lib/shem/llm/middleware/ollama_transport.ex` | Modify — switch to `/api/chat`; inject tools; generate synthetic IDs; decode tool_calls |
| `lib/shem/llm/middleware/llama_cpp_transport.ex` | Modify — switch to `/v1/chat/completions`; inject tools; decode tool_calls |
| `lib/shem/agent/server.ex` | Modify — structured assistant entry with `tool_calls`; `tool_call_id` on tool results; `call.name` throughout |
| `test/shem/llm/request_test.exs` | Modify — add `tools` field tests |
| `test/shem/llm/response_test.exs` | Modify — add `tool_calls` field tests; nil content test |
| `test/shem/agent/tool_dispatch_test.exs` | Modify — schema presence; rename `:tool` → `:name` in all `execute` calls |
| `test/shem/agent/turn_test.exs` | Modify — `parse_response` format; `build_request` tools; `build_messages` shapes; `step` native path |
| `test/shem/llm/middleware/openai_transport_test.exs` | Modify — tools in body; tool_calls parsed; message formatting |
| `test/shem/llm/middleware/anthropic_transport_test.exs` | Modify — `input_schema` format; tool_use parsed; role conversion |
| `test/shem/llm/middleware/ollama_transport_test.exs` | Modify — `/api/chat` endpoint; synthetic IDs; update existing tests |
| `test/shem/llm/middleware/llama_cpp_transport_test.exs` | **Create** — basic completion; tools in body; tool_calls parsed |
| `test/shem/agent/server_test.exs` | Modify — history entries after tool-call turn |

---

## Task 1: Extend `Request` and `Response` structs

**Files:**
- Modify: `lib/shem/llm/request.ex`
- Modify: `lib/shem/llm/response.ex`
- Modify: `test/shem/llm/request_test.exs`
- Modify: `test/shem/llm/response_test.exs`

- [ ] **Step 1: Add tests for `Request.tools` field**

Add to `test/shem/llm/request_test.exs` (inside the module, before the closing `end`):

```elixir
  test "tools defaults to nil" do
    r = %Request{prompt: "hello", model: :default}
    assert is_nil(r.tools)
  end

  test "accepts tool schemas in tools field" do
    tools = [
      %{name: "run_code", description: "Run code.",
        schema: %{type: "object", properties: %{"source" => %{"type" => "string"}}, required: ["source"]}}
    ]
    r = %Request{prompt: "hello", model: :default, tools: tools}
    assert r.tools == tools
  end
```

- [ ] **Step 2: Add tests for `Response.tool_calls` field and nil content**

Add to `test/shem/llm/response_test.exs` (inside the module, before the closing `end`):

```elixir
  test "tool_calls defaults to nil" do
    r = %Response{tokens_used: 10, model: :default, latency_ms: 100}
    assert is_nil(r.tool_calls)
  end

  test "content can be nil" do
    r = %Response{tokens_used: 10, model: :default, latency_ms: 100}
    assert is_nil(r.content)
  end

  test "accepts tool_calls list" do
    calls = [%{id: "call_1", name: "run_code", args: %{"source" => "42"}}]
    r = %Response{tokens_used: 10, model: :default, latency_ms: 100, tool_calls: calls}
    assert r.tool_calls == calls
  end
```

- [ ] **Step 3: Run new tests to verify they fail**

```bash
cd /home/philip/Downloads/_project/shem
mix test test/shem/llm/request_test.exs test/shem/llm/response_test.exs 2>&1 | tail -10
```

Expected: failures — `tools` and `tool_calls` fields do not exist yet; `%Response{}` without `content` raises because `content` is in `@enforce_keys`.

- [ ] **Step 4: Replace `lib/shem/llm/request.ex`**

```elixir
defmodule Shem.LLM.Request do
  @enforce_keys [:prompt, :model]
  defstruct [:prompt, :model, :session_id, :system, :messages, :tools, options: %{}]

  @type message :: %{role: :user | :assistant | :tool, content: String.t()}

  @type tool_schema :: %{
          name: String.t(),
          description: String.t(),
          schema: %{type: String.t(), properties: map(), required: [String.t()]}
        }

  @type t :: %__MODULE__{
          prompt: String.t(),
          model: atom(),
          options: map(),
          session_id: String.t() | nil,
          system: String.t() | nil,
          messages: [message()] | nil,
          tools: [tool_schema()] | nil
        }
end
```

- [ ] **Step 5: Replace `lib/shem/llm/response.ex`**

`content` is dropped from `@enforce_keys` (it can be nil when the model returns only tool calls).

```elixir
defmodule Shem.LLM.Response do
  @enforce_keys [:tokens_used, :model, :latency_ms]
  defstruct [:content, :tool_calls, :tokens_used, :model, :latency_ms]

  @type tool_call :: %{id: String.t(), name: String.t(), args: map()}

  @type t :: %__MODULE__{
          content: String.t() | nil,
          tool_calls: [tool_call()] | nil,
          tokens_used: non_neg_integer(),
          model: atom(),
          latency_ms: non_neg_integer()
        }
end
```

- [ ] **Step 6: Run tests**

```bash
mix test test/shem/llm/request_test.exs test/shem/llm/response_test.exs 2>&1 | tail -10
```

Expected: all tests in both files pass.

- [ ] **Step 7: Run full suite to check for regressions**

```bash
mix test 2>&1 | tail -5
```

Expected: same pass count as before (583), 0 failures. (All existing code constructs `Response` with `content` present — dropping it from enforce_keys is purely additive.)

- [ ] **Step 8: Commit**

```bash
git add lib/shem/llm/request.ex lib/shem/llm/response.ex \
        test/shem/llm/request_test.exs test/shem/llm/response_test.exs
git commit -m "feat: LLM structs — add tools to Request, tool_calls to Response"
```

---

## Task 2: `ToolDispatch` — inline schemas and key rename

**Files:**
- Modify: `lib/shem/agent/tool_dispatch.ex`
- Modify: `test/shem/agent/tool_dispatch_test.exs`

- [ ] **Step 1: Update all `execute` calls in tests to use `:name` key**

In `test/shem/agent/tool_dispatch_test.exs`, every `%{tool: ...}` in an `execute` call must become `%{name: ...}`. There are ~20 occurrences. Replace globally:

```bash
sed -i 's/ToolDispatch\.execute(%{tool:/ToolDispatch.execute(%{name:/g' \
    test/shem/agent/tool_dispatch_test.exs
```

Verify the substitution with:
```bash
grep "execute(%{" test/shem/agent/tool_dispatch_test.exs | head -10
```

Expected: all `execute` calls show `%{name:`, none show `%{tool:`.

- [ ] **Step 2: Add schema presence test**

Add to `test/shem/agent/tool_dispatch_test.exs` (inside the `describe "build_manifest/1"` block, before its closing `end`):

```elixir
    test "builtin tools carry a :schema map with type, properties, required" do
      config = %Config{task: "t", system_prompt: "s", tools: []}
      manifest = ToolDispatch.build_manifest(config)
      builtins = Enum.filter(manifest, &(&1.source == :builtin))
      Enum.each(builtins, fn entry ->
        assert is_map(entry.schema), "#{entry.name} missing :schema"
        assert entry.schema.type == "object"
        assert is_map(entry.schema.properties)
        assert is_list(entry.schema.required)
      end)
    end

    test "run_code schema requires source, makes timeout_ms optional" do
      config = %Config{task: "t", system_prompt: "s", tools: []}
      manifest = ToolDispatch.build_manifest(config)
      run_code = Enum.find(manifest, &(&1.name == "run_code"))
      assert "source" in run_code.schema.required
      refute "timeout_ms" in run_code.schema.required
      assert Map.has_key?(run_code.schema.properties, "source")
      assert Map.has_key?(run_code.schema.properties, "timeout_ms")
    end

    test "Lab tools carry a permissive fallback schema" do
      source = """
      defmodule SchemaFallbackTool do
        def run(_args), do: :ok
      end
      """
      test_src = """
      defmodule SchemaFallbackToolTest do
        def run do
          assert SchemaFallbackTool.run(%{}) == :ok
        end
      end
      """
      {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
      config = %Config{task: "t", system_prompt: "s", tools: []}
      manifest = ToolDispatch.build_manifest(config)
      entry = Enum.find(manifest, &(&1.name == tool.name))
      assert entry.schema == %{type: "object", properties: %{}, required: []}
    end
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
mix test test/shem/agent/tool_dispatch_test.exs 2>&1 | tail -10
```

Expected: failures — `execute` tests fail (`:name` key not matched), schema tests fail (no `:schema` field).

- [ ] **Step 4: Replace `@builtins` in `lib/shem/agent/tool_dispatch.ex`**

Replace the `@builtins` module attribute with:

```elixir
  @builtins [
    %{
      name: "list_tools",
      description: "List all tools currently available.",
      source: :builtin,
      trust: :builtin,
      schema: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "run_code",
      description: "Run Elixir source defining a module with run/0. Returns the result.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{
          "source"     => %{"type" => "string"},
          "timeout_ms" => %{"type" => "integer"}
        },
        required: ["source"]
      }
    },
    %{
      name: "write_tool",
      description: "Graduate a new Elixir tool into the Lab.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{
          "source"      => %{"type" => "string"},
          "test_source" => %{"type" => "string"}
        },
        required: ["source", "test_source"]
      }
    },
    %{
      name: "read_file",
      description: "Read a file and return its contents.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{"path" => %{"type" => "string"}},
        required: ["path"]
      }
    },
    %{
      name: "write_file",
      description: "Write content to a file.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{
          "path"    => %{"type" => "string"},
          "content" => %{"type" => "string"}
        },
        required: ["path", "content"]
      }
    },
    %{
      name: "list_dir",
      description: "List entries in a directory.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{"path" => %{"type" => "string"}},
        required: ["path"]
      }
    },
    %{
      name: "shell",
      description: "Run a shell command and return stdout. Args: cmd (string), timeout_ms (integer, optional, default 10000). NOTE: runs locally until Phase 9b K8s executor.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{
          "cmd"        => %{"type" => "string"},
          "timeout_ms" => %{"type" => "integer"}
        },
        required: ["cmd"]
      }
    }
  ]
```

- [ ] **Step 5: Add permissive fallback schema to Lab and MCP tool maps in `build_manifest/1`**

In `build_manifest/1`, update the Lab tools map to add `schema`:

```elixir
        %{
          name: tool.name,
          description: Map.get(tool.metadata, "description", "graduated tool: #{tool.name}"),
          source: {:lab, tool.id},
          trust: trust,
          schema: %{type: "object", properties: %{}, required: []}
        }
```

And in the MCP tools map:

```elixir
              %{name: t["name"], description: t["description"] || "", source: {:mcp, server}, trust: :external,
                schema: %{type: "object", properties: %{}, required: []}}
```

- [ ] **Step 6: Rename `:tool` → `:name` in `execute/2` pattern matches**

Replace both `execute/2` heads:

```elixir
  @spec execute(%{name: String.t(), args: map()}, [map()]) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(%{name: "list_tools"}, manifest) do
    lines = Enum.map(manifest, fn %{name: n, description: d} -> "- #{n}: #{d}" end)
    {:ok, "Available tools:\n" <> Enum.join(lines, "\n")}
  end

  def execute(%{name: name, args: args}, manifest) do
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

- [ ] **Step 7: Run tool_dispatch tests**

```bash
mix test test/shem/agent/tool_dispatch_test.exs 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 8: Run full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: test count increases by the 3 new schema tests, 0 failures. (`Agent.Server` still calls `ToolDispatch.execute` with `%{tool: name}` — that will break here. Fix: `Agent.Server` is updated in Task 8, so for now expect failures only in server-dependent tests. Alternatively, complete Task 8 before running the full suite — see note below.)

> **Note:** `Agent.Server.execute_tool_calls/4` passes `call` (which has a `.tool` field from `parse_response`) to `ToolDispatch.execute`. Since `ToolDispatch.execute` now matches `:name`, this will cause server-related tests to fail at this step. That is expected — it is fixed in Task 8. Run only the tool_dispatch tests at this step; defer the full suite to after Task 8.

- [ ] **Step 9: Commit**

```bash
git add lib/shem/agent/tool_dispatch.ex test/shem/agent/tool_dispatch_test.exs
git commit -m "feat: ToolDispatch — inline JSON schemas; rename :tool to :name in execute/2"
```

---

## Task 3: `Agent.Turn` — build_request, build_messages, parse_response, step

**Files:**
- Modify: `lib/shem/agent/turn.ex`
- Modify: `test/shem/agent/turn_test.exs`

- [ ] **Step 1: Update `parse_response/1` tests to use new return format**

In `test/shem/agent/turn_test.exs`, inside the `describe "parse_response/1"` block, update every assertion that checks the returned call map. The key changes: `:tool` → `:name`, add `id: nil`. Update the affected tests to:

```elixir
    test "extracts a single tool call embedded in prose" do
      content = ~s(I'll write a tool.\n{"tool": "write_tool", "args": {"name": "Foo"}}\nDone.)
      assert {:tool_calls, [call], ^content} = Turn.parse_response(content)
      assert call == %{id: nil, name: "write_tool", args: %{"name" => "Foo"}}
    end

    test "extracts multiple tool calls" do
      content = ~s({"tool": "run_code", "args": {"source": "x"}}\n{"tool": "list_tools", "args": {}})
      assert {:tool_calls, [c1, c2], ^content} = Turn.parse_response(content)
      assert c1.name == "run_code"
      assert c2.name == "list_tools"
    end

    test "handles tool call with no args key — defaults to empty map" do
      content = ~s({"tool": "list_tools"})
      assert {:tool_calls, [%{id: nil, name: "list_tools", args: %{}}], ^content} =
               Turn.parse_response(content)
    end

    test "tool call where args is not a map — falls back to empty args" do
      content = ~s({"tool": "foo", "args": "not_a_map"})
      assert {:tool_calls, [%{id: nil, name: "foo", args: %{}}], ^content} =
               Turn.parse_response(content)
    end

    test "parse_response strips <think> block before extracting tool calls" do
      content = "<think>\nLet me think. {\"tool\": \"fake\", \"args\": {}}\n</think>\n{\"tool\": \"list_tools\", \"args\": {}}"
      assert {:tool_calls, [%{name: "list_tools"}], _} =
               Turn.parse_response(Turn.strip_thinking(content))
    end

    test "parse_response on content without <think> block is unchanged" do
      content = "{\"tool\": \"list_tools\", \"args\": {}}"
      assert {:tool_calls, [%{name: "list_tools"}], _} = Turn.parse_response(content)
    end
```

- [ ] **Step 2: Replace the three `build_request/4` tests that will break**

In `test/shem/agent/turn_test.exs`, inside `describe "build_request/4"`, replace these three tests:

- `"messages contains tool header when manifest is non-empty"` (line ~164)
- `"messages has no tool header when manifest is empty"` (line ~172)
- `"history :tool role maps to :user in messages"` (line ~177)

with:

```elixir
    test "tools field populated from manifest when non-empty" do
      request = Turn.build_request(:default, "sys", @req_manifest, [%{role: :user, content: "task"}])
      assert is_list(request.tools)
      assert length(request.tools) == length(@req_manifest)
      assert hd(request.tools).name == "list_tools"
    end

    test "tools field is nil when manifest is empty" do
      request = Turn.build_request(:default, "sys", [], [%{role: :user, content: "task"}])
      assert is_nil(request.tools)
    end

    test "messages has no tool header — tool manifest no longer injected as user message" do
      request = Turn.build_request(:default, "sys", @req_manifest, [%{role: :user, content: "task"}])
      refute Enum.any?(request.messages, fn m ->
        is_binary(m.content) and String.contains?(m.content, "Available tools")
      end)
    end

    test "history :tool role is preserved in messages (no longer mapped to :user)" do
      history = [
        %{role: :user,      content: "task"},
        %{role: :assistant, content: "calling"},
        %{role: :tool,      content: "Tool result: 42"}
      ]
      request = Turn.build_request(:default, "sys", [], history)
      roles = Enum.map(request.messages, & &1.role)
      assert :tool in roles
    end

    test "assistant tool_calls preserved in messages" do
      history = [
        %{role: :user,      content: "task"},
        %{role: :assistant, content: nil,
          tool_calls: [%{id: "c1", name: "run_code", args: %{"source" => "1"}}]}
      ]
      request = Turn.build_request(:default, "sys", [], history)
      assistant = Enum.find(request.messages, &(&1.role == :assistant))
      assert assistant.tool_calls == [%{id: "c1", name: "run_code", args: %{"source" => "1"}}]
    end

    test "tool result with tool_call_id preserved in messages" do
      history = [
        %{role: :user, content: "task"},
        %{role: :tool, content: "42", tool_call_id: "c1"}
      ]
      request = Turn.build_request(:default, "sys", [], history)
      tool_msg = Enum.find(request.messages, &(&1.role == :tool))
      assert tool_msg.tool_call_id == "c1"
    end
```

- [ ] **Step 3: Add `step/4` native path test**

Add inside `describe "step/4"` (or create it if absent) in `test/shem/agent/turn_test.exs`:

```elixir
  describe "step/4 — native tool_calls path" do
    test "returns {:tool_calls, calls, content} when Response has tool_calls" do
      tool_call = %{id: "call_1", name: "run_code", args: %{"source" => "1 + 1"}}
      stub_response = %Shem.LLM.Response{
        content: nil,
        tool_calls: [tool_call],
        tokens_used: 5,
        model: :default,
        latency_ms: 10
      }

      config = %Shem.Agent.Config{
        task: "t",
        system_prompt: "sys",
        model: :default,
        max_turns: 5
      }

      # Inject a stub transport that returns the pre-built response
      Application.put_env(:shem, :llm_middleware, [
        {Shem.LLM.StubTransport, [response: {:ok, stub_response}]}
      ])

      result = Turn.step(config, "sess_native_test", [], [])
      assert {:tool_calls, [^tool_call], ""} = result

      Application.delete_env(:shem, :llm_middleware)
    end
  end
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
mix test test/shem/agent/turn_test.exs 2>&1 | tail -15
```

Expected: `parse_response` tests fail (old `:tool` key); three build_request tests fail; step native test fails.

- [ ] **Step 5: Update `parse_response/1` in `lib/shem/agent/turn.ex`**

Replace the `parse_response/1` function:

```elixir
  @spec parse_response(String.t()) ::
          {:tool_calls, [%{id: nil, name: String.t(), args: map()}], String.t()}
          | {:done, String.t()}
  def parse_response(content) do
    pattern = ~r/\{(?:[^{}]|\{[^{}]*\})*\}/

    tool_calls =
      Regex.scan(pattern, content)
      |> Enum.map(&hd/1)
      |> Enum.flat_map(fn json_str ->
        case Jason.decode(json_str) do
          {:ok, %{"tool" => tool, "args" => args}} when is_binary(tool) and is_map(args) ->
            [%{id: nil, name: tool, args: args}]

          {:ok, %{"tool" => tool}} when is_binary(tool) ->
            [%{id: nil, name: tool, args: %{}}]

          _ ->
            []
        end
      end)

    case tool_calls do
      [] -> {:done, content}
      calls -> {:tool_calls, calls, content}
    end
  end
```

- [ ] **Step 6: Update `build_request/4` and replace `build_messages/2` with `build_messages/1`**

Replace the `build_request/4` and `build_messages` functions in `lib/shem/agent/turn.ex`:

```elixir
  @spec build_request(atom(), String.t(), [map()], [map()]) :: Request.t()
  def build_request(model, system_prompt, tools_manifest, history) do
    prompt = build_prompt(system_prompt, tools_manifest, history)

    messages =
      case build_messages(history) do
        [] -> nil
        msgs -> msgs
      end

    tools =
      case Enum.map(tools_manifest, &Map.take(&1, [:name, :description, :schema])) do
        [] -> nil
        ts -> ts
      end

    %Request{prompt: prompt, model: model, system: system_prompt, messages: messages, tools: tools}
  end

  defp build_messages(history) do
    Enum.map(history, fn
      %{role: :user, content: c} ->
        %{role: :user, content: c}

      %{role: :assistant, content: c, tool_calls: calls} ->
        %{role: :assistant, content: c, tool_calls: calls}

      %{role: :assistant, content: c} ->
        %{role: :assistant, content: c}

      %{role: :tool, content: c, tool_call_id: id} ->
        %{role: :tool, content: c, tool_call_id: id}

      %{role: :tool, content: c} ->
        %{role: :tool, content: c}
    end)
  end
```

- [ ] **Step 7: Update `step/4` to check `response.tool_calls` first**

Replace the `step/4` function body in `lib/shem/agent/turn.ex`:

```elixir
  @spec step(Config.t(), String.t(), [map()], [map()]) ::
          {:tool_calls, [%{id: String.t() | nil, name: String.t(), args: map()}], String.t()}
          | {:done, String.t()}
          | {:error, term()}
  def step(%Config{} = config, session_id, history, tools_manifest) do
    request =
      config.model
      |> build_request(config.system_prompt, tools_manifest, history)
      |> Map.put(:session_id, session_id)

    case LLM.complete(request) do
      {:ok, %Response{tool_calls: [_ | _] = calls, content: content}} ->
        {:tool_calls, calls, content || ""}

      {:ok, %Response{content: content}} ->
        content |> strip_thinking() |> parse_response()

      {:error, reason} ->
        {:error, reason}
    end
  end
```

- [ ] **Step 8: Run turn tests**

```bash
mix test test/shem/agent/turn_test.exs 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
git add lib/shem/agent/turn.ex test/shem/agent/turn_test.exs
git commit -m "feat: Agent.Turn — tools in request, drop text tool header, native tool_calls in step/4"
```

---

## Task 4: `OpenAITransport` — tools injection and tool_calls decoding

**Files:**
- Modify: `lib/shem/llm/middleware/openai_transport.ex`
- Modify: `test/shem/llm/middleware/openai_transport_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/shem/llm/middleware/openai_transport_test.exs` (before the closing `end`):

```elixir
  describe "call/3 — native tool calling" do
    defp tool_call_body(id, name, args_map) do
      %{
        "choices" => [%{"message" => %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [%{
            "id" => id,
            "type" => "function",
            "function" => %{"name" => name, "arguments" => Jason.encode!(args_map)}
          }]
        }}],
        "usage" => %{"total_tokens" => 15}
      }
    end

    test "injects tools array with function wrapper when request.tools is non-nil" do
      tools = [%{name: "run_code", description: "Run code.",
                 schema: %{type: "object", properties: %{"source" => %{"type" => "string"}}, required: ["source"]}}]
      request = %Request{prompt: "fallback", model: :default, tools: tools}

      mock = fn _url, opts ->
        body = opts[:json]
        assert body["tool_choice"] == "auto"
        [tool] = body["tools"]
        assert tool["type"] == "function"
        assert tool["function"]["name"] == "run_code"
        assert tool["function"]["parameters"]["required"] == ["source"]
        {:ok, %{status: 200, body: success_body("ok", 5)}}
      end

      opts = [api_key: "sk-test", http_post_fn: mock]
      assert {:ok, %Response{}} = OpenAITransport.call(request, opts, nil)
    end

    test "does not inject tools or tool_choice when request.tools is nil" do
      request = %Request{prompt: "hello", model: :default}

      mock = fn _url, opts ->
        body = opts[:json]
        refute Map.has_key?(body, "tools")
        refute Map.has_key?(body, "tool_choice")
        {:ok, %{status: 200, body: success_body("hi", 5)}}
      end

      opts = [api_key: "sk-test", http_post_fn: mock]
      assert {:ok, %Response{content: "hi"}} = OpenAITransport.call(request, opts, nil)
    end

    test "decodes tool_calls from response into Response.tool_calls" do
      request = %Request{prompt: "hello", model: :default}

      mock = fn _url, _opts ->
        {:ok, %{status: 200, body: tool_call_body("call_1", "run_code", %{"source" => "1+1"})}}
      end

      opts = [api_key: "sk-test", http_post_fn: mock]
      assert {:ok, %Response{tool_calls: [call]}} = OpenAITransport.call(request, opts, nil)
      assert call == %{id: "call_1", name: "run_code", args: %{"source" => "1+1"}}
    end

    test "formats assistant tool_calls history entry correctly in messages array" do
      tc = [%{id: "c1", name: "shell", args: %{"cmd" => "echo hi"}}]
      history_msgs = [
        %{role: :user,      content: "task"},
        %{role: :assistant, content: nil, tool_calls: tc},
        %{role: :tool,      content: "hi\n", tool_call_id: "c1"}
      ]
      request = %Request{prompt: "fallback", model: :default, messages: history_msgs}

      mock = fn _url, opts ->
        msgs = opts[:json]["messages"]
        # system prepend not present (no request.system)
        assert Enum.any?(msgs, &(&1["role"] == "assistant" and is_list(&1["tool_calls"])))
        [tool_call_msg] = Enum.filter(msgs, &(&1["role"] == "tool"))
        assert tool_call_msg["tool_call_id"] == "c1"
        assert tool_call_msg["content"] == "hi\n"
        {:ok, %{status: 200, body: success_body("done", 5)}}
      end

      opts = [api_key: "sk-test", http_post_fn: mock]
      assert {:ok, %Response{}} = OpenAITransport.call(request, opts, nil)
    end
  end
```

- [ ] **Step 2: Run to verify tests fail**

```bash
mix test test/shem/llm/middleware/openai_transport_test.exs 2>&1 | tail -10
```

Expected: 4 new failures.

- [ ] **Step 3: Replace `lib/shem/llm/middleware/openai_transport.ex`**

```elixir
defmodule Shem.LLM.Middleware.OpenAITransport do
  @behaviour Shem.LLM.Middleware

  @impl true
  def call(request, opts, _next) do
    api_key = Keyword.get(opts, :api_key, System.get_env("OPENAI_API_KEY"))

    if is_nil(api_key) or api_key == "" do
      {:error, {:transport, :missing_api_key}}
    else
      base_url   = Keyword.get(opts, :base_url, "https://api.openai.com")
      http_post  = Keyword.get(opts, :http_post_fn, &Req.post/2)
      timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))
      model_str  = Keyword.get(opts, :model_string, "gpt-4o")
      max_tokens = Map.get(request.options, :max_tokens, 512)

      messages =
        case request.messages do
          nil ->
            [%{"role" => "user", "content" => request.prompt}]

          msgs ->
            system_msgs =
              if request.system,
                do: [%{"role" => "system", "content" => request.system}],
                else: []

            system_msgs ++ format_messages(msgs)
        end

      base_body = %{
        "model"      => model_str,
        "messages"   => messages,
        "max_tokens" => max_tokens
      }

      body =
        case request.tools do
          nil -> base_body
          tools ->
            base_body
            |> Map.put("tools", format_tools(tools))
            |> Map.put("tool_choice", "auto")
        end

      headers  = [{"authorization", "Bearer #{api_key}"}]
      start_ms = System.monotonic_time(:millisecond)

      case http_post.(base_url <> "/v1/chat/completions",
             json: body,
             headers: headers,
             receive_timeout: timeout_ms
           ) do
        {:ok, %{status: 200, body: resp_body}} -> parse_response(resp_body, request.model, start_ms)
        {:ok, %{status: 401}}                  -> {:error, {:transport, :unauthorized}}
        {:ok, %{status: 429}}                  -> {:error, {:transport, :rate_limited}}
        {:ok, %{status: status}}               -> {:error, {:transport, {:http_error, status}}}
        {:error, reason}                       -> {:error, {:transport, reason}}
      end
    end
  end

  defp format_tools(tools) do
    Enum.map(tools, fn %{name: n, description: d, schema: s} ->
      %{"type" => "function",
        "function" => %{
          "name"        => n,
          "description" => d,
          "parameters"  => %{
            "type"       => s.type,
            "properties" => s.properties,
            "required"   => s.required
          }
        }}
    end)
  end

  defp format_messages(msgs) do
    Enum.map(msgs, fn
      %{role: :assistant, content: c, tool_calls: calls} ->
        %{"role"       => "assistant",
          "content"    => c,
          "tool_calls" => Enum.map(calls, fn %{id: id, name: n, args: a} ->
            %{"id" => id, "type" => "function",
              "function" => %{"name" => n, "arguments" => Jason.encode!(a)}}
          end)}

      %{role: :tool, tool_call_id: id, content: c} ->
        %{"role" => "tool", "tool_call_id" => id, "content" => c}

      %{role: role, content: c} ->
        %{"role" => to_string(role), "content" => c}
    end)
  end

  defp parse_response(
         %{"choices" => [%{"message" => message} | _], "usage" => usage},
         model,
         start_ms
       ) do
    content       = message["content"]
    raw_calls     = message["tool_calls"]
    tokens_used   = Map.get(usage, "total_tokens", 0)
    latency_ms    = System.monotonic_time(:millisecond) - start_ms

    tool_calls =
      if raw_calls do
        Enum.map(raw_calls, fn %{"id" => id, "function" => %{"name" => n, "arguments" => args_str}} ->
          %{id: id, name: n, args: Jason.decode!(args_str)}
        end)
      end

    {:ok,
     %Shem.LLM.Response{
       content:     content,
       tool_calls:  tool_calls,
       tokens_used: tokens_used,
       model:       model,
       latency_ms:  latency_ms
     }}
  end

  defp parse_response(raw_body, _model, _start_ms) do
    {:error, {:parse_error, raw_body}}
  end
end
```

- [ ] **Step 4: Run OpenAI transport tests**

```bash
mix test test/shem/llm/middleware/openai_transport_test.exs 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/middleware/openai_transport.ex \
        test/shem/llm/middleware/openai_transport_test.exs
git commit -m "feat: OpenAITransport — native tool calling; tools array, tool_calls decoding"
```

---

## Task 5: `AnthropicTransport` — input_schema format and tool_use decoding

**Files:**
- Modify: `lib/shem/llm/middleware/anthropic_transport.ex`
- Modify: `test/shem/llm/middleware/anthropic_transport_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/shem/llm/middleware/anthropic_transport_test.exs` (before the closing `end`):

```elixir
  describe "call/3 — native tool calling" do
    defp tool_use_body(id, name, input_map, input_tokens \\ 5, output_tokens \\ 3) do
      %{
        "content" => [
          %{"type" => "tool_use", "id" => id, "name" => name, "input" => input_map}
        ],
        "usage" => %{"input_tokens" => input_tokens, "output_tokens" => output_tokens}
      }
    end

    test "injects tools with input_schema format (no type:function wrapper)" do
      tools = [%{name: "shell", description: "Run shell.",
                 schema: %{type: "object", properties: %{"cmd" => %{"type" => "string"}}, required: ["cmd"]}}]
      request = %Request{prompt: "fallback", model: :default, tools: tools}

      mock = fn _url, opts ->
        body = opts[:json]
        [tool] = body["tools"]
        assert tool["name"] == "shell"
        assert Map.has_key?(tool, "input_schema")
        refute Map.has_key?(tool, "type")
        assert tool["input_schema"]["required"] == ["cmd"]
        {:ok, %{status: 200, body: success_body("ok", 5, 2)}}
      end

      opts = [api_key: "sk-ant-test", http_post_fn: mock]
      assert {:ok, %Response{}} = AnthropicTransport.call(request, opts, nil)
    end

    test "decodes tool_use content block into Response.tool_calls" do
      request = %Request{prompt: "hello", model: :default}

      mock = fn _url, _opts ->
        {:ok, %{status: 200, body: tool_use_body("toolu_01", "shell", %{"cmd" => "echo hi"})}}
      end

      opts = [api_key: "sk-ant-test", http_post_fn: mock]
      assert {:ok, %Response{tool_calls: [call]}} = AnthropicTransport.call(request, opts, nil)
      assert call == %{id: "toolu_01", name: "shell", args: %{"cmd" => "echo hi"}}
    end

    test "extracts text alongside tool_use when both present" do
      body = %{
        "content" => [
          %{"type" => "text",     "text" => "I'll run that."},
          %{"type" => "tool_use", "id" => "toolu_02", "name" => "shell", "input" => %{"cmd" => "ls"}}
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 3}
      }
      request = %Request{prompt: "hello", model: :default}
      mock = fn _url, _opts -> {:ok, %{status: 200, body: body}} end
      opts = [api_key: "sk-ant-test", http_post_fn: mock]

      assert {:ok, %Response{content: "I'll run that.", tool_calls: [_]}} =
               AnthropicTransport.call(request, opts, nil)
    end

    test "formats assistant tool_calls as content-block array" do
      tc = [%{id: "toolu_03", name: "shell", args: %{"cmd" => "pwd"}}]
      history_msgs = [
        %{role: :user,      content: "task"},
        %{role: :assistant, content: nil, tool_calls: tc},
        %{role: :tool,      content: "/home", tool_call_id: "toolu_03"}
      ]
      request = %Request{prompt: "fallback", model: :default, messages: history_msgs}

      mock = fn _url, opts ->
        msgs = opts[:json]["messages"]
        assistant_msg = Enum.find(msgs, &(&1["role"] == "assistant"))
        assert is_list(assistant_msg["content"])
        [block] = Enum.filter(assistant_msg["content"], &(&1["type"] == "tool_use"))
        assert block["id"] == "toolu_03"

        # tool result goes as role: "user" with tool_result content block
        user_msgs = Enum.filter(msgs, &(&1["role"] == "user"))
        tool_result_msg = Enum.find(user_msgs, fn m ->
          is_list(m["content"]) and hd(m["content"])["type"] == "tool_result"
        end)
        assert tool_result_msg["content"] == [
          %{"type" => "tool_result", "tool_use_id" => "toolu_03", "content" => "/home"}
        ]

        {:ok, %{status: 200, body: success_body("done", 5, 2)}}
      end

      opts = [api_key: "sk-ant-test", http_post_fn: mock]
      assert {:ok, %Response{}} = AnthropicTransport.call(request, opts, nil)
    end
  end
```

- [ ] **Step 2: Run to verify tests fail**

```bash
mix test test/shem/llm/middleware/anthropic_transport_test.exs 2>&1 | tail -10
```

Expected: 4 new failures.

- [ ] **Step 3: Replace `lib/shem/llm/middleware/anthropic_transport.ex`**

```elixir
defmodule Shem.LLM.Middleware.AnthropicTransport do
  @behaviour Shem.LLM.Middleware

  @impl true
  def call(request, opts, _next) do
    api_key = Keyword.get(opts, :api_key, System.get_env("ANTHROPIC_API_KEY"))

    if is_nil(api_key) or api_key == "" do
      {:error, {:transport, :missing_api_key}}
    else
      http_post  = Keyword.get(opts, :http_post_fn, &Req.post/2)
      timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))
      model_str  = Keyword.get(opts, :model_string, "claude-sonnet-4-6")
      max_tokens = Map.get(request.options, :max_tokens, 512)
      base_url   = Keyword.get(opts, :base_url, "https://api.anthropic.com")

      {body_messages, maybe_system} =
        case request.messages do
          nil ->
            {[%{"role" => "user", "content" => request.prompt}], nil}

          msgs ->
            {format_messages(msgs), request.system}
        end

      base_body = %{
        "model"      => model_str,
        "messages"   => body_messages,
        "max_tokens" => max_tokens
      }

      body =
        base_body
        |> then(fn b -> if maybe_system, do: Map.put(b, "system", maybe_system), else: b end)
        |> then(fn b ->
          case request.tools do
            nil   -> b
            tools -> Map.put(b, "tools", format_tools(tools))
          end
        end)

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"}
      ]

      start_ms = System.monotonic_time(:millisecond)

      case http_post.(base_url <> "/v1/messages",
             json: body,
             headers: headers,
             receive_timeout: timeout_ms
           ) do
        {:ok, %{status: 200, body: resp_body}} -> parse_response(resp_body, request.model, start_ms)
        {:ok, %{status: 401}}                  -> {:error, {:transport, :unauthorized}}
        {:ok, %{status: 429}}                  -> {:error, {:transport, :rate_limited}}
        {:ok, %{status: status}}               -> {:error, {:transport, {:http_error, status}}}
        {:error, reason}                       -> {:error, {:transport, reason}}
      end
    end
  end

  defp format_tools(tools) do
    Enum.map(tools, fn %{name: n, description: d, schema: s} ->
      %{"name"         => n,
        "description"  => d,
        "input_schema" => %{
          "type"       => s.type,
          "properties" => s.properties,
          "required"   => s.required
        }}
    end)
  end

  defp format_messages(msgs) do
    Enum.map(msgs, fn
      %{role: :assistant, content: c, tool_calls: calls} ->
        text_blocks =
          if c && c != "", do: [%{"type" => "text", "text" => c}], else: []

        call_blocks =
          Enum.map(calls, fn %{id: id, name: n, args: a} ->
            %{"type" => "tool_use", "id" => id, "name" => n, "input" => a}
          end)

        %{"role" => "assistant", "content" => text_blocks ++ call_blocks}

      %{role: :tool, tool_call_id: id, content: c} ->
        %{"role"    => "user",
          "content" => [%{"type" => "tool_result", "tool_use_id" => id, "content" => c}]}

      %{role: role, content: c} ->
        %{"role" => to_string(role), "content" => c}
    end)
  end

  defp parse_response(
         %{"content" => content_blocks, "usage" => usage},
         model,
         start_ms
       )
       when is_list(content_blocks) do
    tokens_used = Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)
    latency_ms  = System.monotonic_time(:millisecond) - start_ms

    text =
      content_blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("", & &1["text"])

    raw_tool_calls = Enum.filter(content_blocks, &(&1["type"] == "tool_use"))

    tool_calls =
      if raw_tool_calls == [] do
        nil
      else
        Enum.map(raw_tool_calls, fn %{"id" => id, "name" => n, "input" => a} ->
          %{id: id, name: n, args: a}
        end)
      end

    {:ok,
     %Shem.LLM.Response{
       content:     if(text == "", do: nil, else: text),
       tool_calls:  tool_calls,
       tokens_used: tokens_used,
       model:       model,
       latency_ms:  latency_ms
     }}
  end

  defp parse_response(raw_body, _model, _start_ms) do
    {:error, {:parse_error, raw_body}}
  end
end
```

- [ ] **Step 4: Run Anthropic transport tests**

```bash
mix test test/shem/llm/middleware/anthropic_transport_test.exs 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/middleware/anthropic_transport.ex \
        test/shem/llm/middleware/anthropic_transport_test.exs
git commit -m "feat: AnthropicTransport — input_schema tools, tool_use decoding, role conversion"
```

---

## Task 6: `OllamaTransport` — switch to `/api/chat` and native tool calling

**Files:**
- Modify: `lib/shem/llm/middleware/ollama_transport.ex`
- Modify: `test/shem/llm/middleware/ollama_transport_test.exs`

- [ ] **Step 1: Update existing tests for new endpoint and response shape**

In `test/shem/llm/middleware/ollama_transport_test.exs`:

Replace the `ollama_body/3` helper:

```elixir
  defp ollama_body(content, eval \\ 20, prompt_eval \\ 10) do
    %{
      "message" => %{"role" => "assistant", "content" => content},
      "done" => true,
      "eval_count" => eval,
      "prompt_eval_count" => prompt_eval
    }
  end
```

Update the URL in existing test options from `"http://localhost:11434"` — the endpoint changes from `/api/generate` to `/api/chat`, but if tests construct the URL through `opts`, no URL string change is needed in the test unless the test asserts on the URL. Check whether any test asserts on `_url` — if so, update the expected path to `/api/chat`.

- [ ] **Step 2: Add new tests for tools and tool_calls**

Add to `test/shem/llm/middleware/ollama_transport_test.exs` (before the closing `end`):

```elixir
  describe "native tool calling" do
    defp ollama_tool_call_body(name, args_map) do
      %{
        "message" => %{
          "role"       => "assistant",
          "content"    => "",
          "tool_calls" => [%{"function" => %{"name" => name, "arguments" => args_map}}]
        },
        "done" => true,
        "eval_count" => 10,
        "prompt_eval_count" => 5
      }
    end

    test "injects tools array in OpenAI format when request.tools non-nil" do
      tools = [%{name: "shell", description: "Run shell.",
                 schema: %{type: "object", properties: %{"cmd" => %{"type" => "string"}}, required: ["cmd"]}}]
      req = %Request{prompt: "hello", model: :default, options: %{}, tools: tools}

      mock = fn _url, opts ->
        body = opts[:json]
        [tool] = body["tools"]
        assert tool["type"] == "function"
        assert tool["function"]["name"] == "shell"
        {:ok, %{status: 200, body: ollama_body("done")}}
      end

      opts = [http_post_fn: mock, url: "http://localhost:11434"]
      assert {:ok, %Response{}} = OllamaTransport.call(req, opts, nil)
    end

    test "decodes tool_calls from response with synthetic ids" do
      req = %Request{prompt: "hello", model: :default, options: %{}}

      mock = fn _url, _opts ->
        {:ok, %{status: 200, body: ollama_tool_call_body("shell", %{"cmd" => "ls"})}}
      end

      opts = [http_post_fn: mock, url: "http://localhost:11434"]
      assert {:ok, %Response{tool_calls: [call]}} = OllamaTransport.call(req, opts, nil)
      assert call.name == "shell"
      assert call.args == %{"cmd" => "ls"}
      assert is_binary(call.id) and call.id != ""
    end

    test "formats tool result messages without tool_call_id for ollama" do
      tc = [%{id: "ollama_99", name: "shell", args: %{"cmd" => "echo hi"}}]
      history_msgs = [
        %{role: :user,      content: "task"},
        %{role: :assistant, content: nil, tool_calls: tc},
        %{role: :tool,      content: "hi\n", tool_call_id: "ollama_99"}
      ]
      req = %Request{prompt: "fallback", model: :default, options: %{}, messages: history_msgs}

      mock = fn _url, opts ->
        msgs = opts[:json]["messages"]
        tool_msg = Enum.find(msgs, &(&1["role"] == "tool"))
        assert tool_msg["content"] == "hi\n"
        refute Map.has_key?(tool_msg, "tool_call_id")
        {:ok, %{status: 200, body: ollama_body("done")}}
      end

      opts = [http_post_fn: mock, url: "http://localhost:11434"]
      assert {:ok, %Response{}} = OllamaTransport.call(req, opts, nil)
    end
  end
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
mix test test/shem/llm/middleware/ollama_transport_test.exs 2>&1 | tail -10
```

Expected: existing tests fail (wrong endpoint/body shape); new tests fail.

- [ ] **Step 4: Replace `lib/shem/llm/middleware/ollama_transport.ex`**

```elixir
defmodule Shem.LLM.Middleware.OllamaTransport do
  @behaviour Shem.LLM.Middleware

  require Logger

  @impl true
  def call(request, opts, _next) do
    url       = Keyword.get(opts, :url, Application.get_env(:shem, :llm_ollama_url, "http://localhost:11434"))
    http_post = Keyword.get(opts, :http_post_fn, &Req.post/2)

    messages =
      case request.messages do
        nil  -> [%{"role" => "user", "content" => request.prompt}]
        msgs -> format_messages(msgs)
      end

    base_body = %{
      "model"   => resolve_model(request.model, opts),
      "messages" => messages,
      "stream"  => false
    }

    body =
      case request.tools do
        nil   -> base_body
        tools -> Map.put(base_body, "tools", format_tools(tools))
      end

    start_ms = System.monotonic_time(:millisecond)

    case http_post.(url <> "/api/chat", json: body) do
      {:ok, %{status: 200, body: resp_body}} -> parse_response(resp_body, request.model, start_ms)
      {:ok, %{status: status}}               -> {:error, {:transport, {:http_error, status}}}
      {:error, reason}                       -> {:error, {:transport, reason}}
    end
  end

  defp format_tools(tools) do
    Enum.map(tools, fn %{name: n, description: d, schema: s} ->
      %{"type" => "function",
        "function" => %{
          "name"        => n,
          "description" => d,
          "parameters"  => %{
            "type"       => s.type,
            "properties" => s.properties,
            "required"   => s.required
          }
        }}
    end)
  end

  defp format_messages(msgs) do
    Enum.map(msgs, fn
      %{role: :assistant, content: c, tool_calls: calls} ->
        %{"role"       => "assistant",
          "content"    => c,
          "tool_calls" => Enum.map(calls, fn %{name: n, args: a} ->
            %{"function" => %{"name" => n, "arguments" => a}}
          end)}

      %{role: :tool, content: c, tool_call_id: _} ->
        %{"role" => "tool", "content" => c}

      %{role: :tool, content: c} ->
        %{"role" => "tool", "content" => c}

      %{role: role, content: c} ->
        %{"role" => to_string(role), "content" => c}
    end)
  end

  defp resolve_model(model_atom, opts) do
    case Keyword.fetch(opts, :model_string) do
      {:ok, str} ->
        str

      :error ->
        models = Application.get_env(:shem, :llm_models, %{})

        case Map.get(models, model_atom) do
          nil ->
            Logger.warning("Unknown LLM model atom #{inspect(model_atom)}, falling back to string")
            Atom.to_string(model_atom)

          str ->
            str
        end
    end
  end

  defp parse_response(%{"message" => message, "done" => true} = body, model, start_ms) do
    content      = message["content"]
    raw_calls    = message["tool_calls"]
    tokens_used  = Map.get(body, "eval_count", 0) + Map.get(body, "prompt_eval_count", 0)
    latency_ms   = System.monotonic_time(:millisecond) - start_ms

    tool_calls =
      if raw_calls do
        Enum.map(raw_calls, fn %{"function" => %{"name" => n, "arguments" => a}} ->
          %{id: "ollama_#{:erlang.unique_integer([:positive, :monotonic])}", name: n, args: a}
        end)
      end

    {:ok,
     %Shem.LLM.Response{
       content:     if(content == "" or is_nil(content), do: nil, else: content),
       tool_calls:  tool_calls,
       tokens_used: tokens_used,
       model:       model,
       latency_ms:  latency_ms
     }}
  end

  defp parse_response(raw_body, _model, _start_ms) do
    {:error, {:parse_error, raw_body}}
  end
end
```

- [ ] **Step 5: Run Ollama transport tests**

```bash
mix test test/shem/llm/middleware/ollama_transport_test.exs 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/llm/middleware/ollama_transport.ex \
        test/shem/llm/middleware/ollama_transport_test.exs
git commit -m "feat: OllamaTransport — switch to /api/chat, tools injection, synthetic IDs"
```

---

## Task 7: `LlamaCppTransport` — switch to `/v1/chat/completions` and native tool calling

**Files:**
- Modify: `lib/shem/llm/middleware/llama_cpp_transport.ex`
- **Create**: `test/shem/llm/middleware/llama_cpp_transport_test.exs`

- [ ] **Step 1: Create the test file**

```elixir
defmodule Shem.LLM.Middleware.LlamaCppTransportTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.Middleware.LlamaCppTransport
  alias Shem.LLM.{Request, Response}

  defp req(model \\ :default), do: %Request{prompt: "hello", model: model, options: %{}}

  defp mock_post(status, body) do
    fn _url, _opts -> {:ok, %{status: status, body: body}} end
  end

  defp success_body(content, prompt_tokens, completion_tokens) do
    %{
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
      "usage"   => %{"prompt_tokens" => prompt_tokens, "completion_tokens" => completion_tokens}
    }
  end

  defp tool_call_body(id, name, args_map) do
    %{
      "choices" => [%{"message" => %{
        "role"       => "assistant",
        "content"    => nil,
        "tool_calls" => [%{
          "id"       => id,
          "type"     => "function",
          "function" => %{"name" => name, "arguments" => Jason.encode!(args_map)}
        }]
      }}],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
    }
  end

  describe "call/3 — basic completion via /v1/chat/completions" do
    test "returns Response with content and tokens_used" do
      opts = [
        url:          "http://localhost:8080",
        http_post_fn: mock_post(200, success_body("Hello", 10, 5))
      ]
      assert {:ok, %Response{} = resp} = LlamaCppTransport.call(req(), opts, nil)
      assert resp.content == "Hello"
      assert resp.tokens_used == 15
    end

    test "returns unauthorized error on 401" do
      opts = [url: "http://localhost:8080", http_post_fn: mock_post(401, %{})]
      assert {:error, {:transport, :unauthorized}} = LlamaCppTransport.call(req(), opts, nil)
    end

    test "returns http_error tuple for unexpected status" do
      opts = [url: "http://localhost:8080", http_post_fn: mock_post(500, %{})]
      assert {:error, {:transport, {:http_error, 500}}} = LlamaCppTransport.call(req(), opts, nil)
    end

    test "uses messages array (not prompt) in request body" do
      mock = fn _url, opts ->
        body = opts[:json]
        assert Map.has_key?(body, "messages")
        refute Map.has_key?(body, "prompt")
        {:ok, %{status: 200, body: success_body("ok", 5, 5)}}
      end
      opts = [url: "http://localhost:8080", http_post_fn: mock]
      assert {:ok, %Response{}} = LlamaCppTransport.call(req(), opts, nil)
    end
  end

  describe "call/3 — native tool calling" do
    test "injects tools array with function wrapper when request.tools non-nil" do
      tools = [%{name: "run_code", description: "Run code.",
                 schema: %{type: "object", properties: %{"source" => %{"type" => "string"}}, required: ["source"]}}]
      request = %Request{prompt: "fallback", model: :default, options: %{}, tools: tools}

      mock = fn _url, opts ->
        body = opts[:json]
        assert body["tool_choice"] == "auto"
        [tool] = body["tools"]
        assert tool["type"] == "function"
        assert tool["function"]["name"] == "run_code"
        {:ok, %{status: 200, body: success_body("ok", 5, 5)}}
      end

      opts = [url: "http://localhost:8080", http_post_fn: mock]
      assert {:ok, %Response{}} = LlamaCppTransport.call(request, opts, nil)
    end

    test "decodes tool_calls from response, parsing JSON arguments string" do
      request = %Request{prompt: "hello", model: :default, options: %{}}

      mock = fn _url, _opts ->
        {:ok, %{status: 200, body: tool_call_body("call_1", "run_code", %{"source" => "1+1"})}}
      end

      opts = [url: "http://localhost:8080", http_post_fn: mock]
      assert {:ok, %Response{tool_calls: [call]}} = LlamaCppTransport.call(request, opts, nil)
      assert call == %{id: "call_1", name: "run_code", args: %{"source" => "1+1"}}
    end
  end
end
```

- [ ] **Step 2: Run new test file to verify failures**

```bash
mix test test/shem/llm/middleware/llama_cpp_transport_test.exs 2>&1 | tail -10
```

Expected: failures — `/v1/chat/completions` endpoint not used; tools not injected; tool_calls not decoded.

- [ ] **Step 3: Replace `lib/shem/llm/middleware/llama_cpp_transport.ex`**

```elixir
defmodule Shem.LLM.Middleware.LlamaCppTransport do
  @behaviour Shem.LLM.Middleware

  require Logger

  @impl true
  def call(request, opts, _next) do
    url        = Keyword.get(opts, :url, Application.get_env(:shem, :llm_llama_cpp_url, "http://localhost:8080"))
    http_post  = Keyword.get(opts, :http_post_fn, &Req.post/2)
    timeout_ms = Keyword.get(opts, :timeout_ms, Application.get_env(:shem, :llm_timeout_ms, 120_000))
    max_tokens = Map.get(request.options, :max_tokens, 512)

    messages =
      case request.messages do
        nil  -> [%{"role" => "user", "content" => request.prompt}]
        msgs -> format_messages(msgs)
      end

    base_body = %{
      "model"      => resolve_model(request.model, opts),
      "messages"   => messages,
      "max_tokens" => max_tokens,
      "stream"     => false
    }

    body =
      case request.tools do
        nil   -> base_body
        tools ->
          base_body
          |> Map.put("tools", format_tools(tools))
          |> Map.put("tool_choice", "auto")
      end

    start_ms = System.monotonic_time(:millisecond)

    case http_post.(url <> "/v1/chat/completions", json: body, receive_timeout: timeout_ms) do
      {:ok, %{status: 200, body: resp_body}} -> parse_response(resp_body, request.model, start_ms)
      {:ok, %{status: 401}}                  -> {:error, {:transport, :unauthorized}}
      {:ok, %{status: 429}}                  -> {:error, {:transport, :rate_limited}}
      {:ok, %{status: status}}               -> {:error, {:transport, {:http_error, status}}}
      {:error, reason}                       -> {:error, {:transport, reason}}
    end
  end

  defp format_tools(tools) do
    Enum.map(tools, fn %{name: n, description: d, schema: s} ->
      %{"type" => "function",
        "function" => %{
          "name"        => n,
          "description" => d,
          "parameters"  => %{
            "type"       => s.type,
            "properties" => s.properties,
            "required"   => s.required
          }
        }}
    end)
  end

  defp format_messages(msgs) do
    Enum.map(msgs, fn
      %{role: :assistant, content: c, tool_calls: calls} ->
        %{"role"       => "assistant",
          "content"    => c,
          "tool_calls" => Enum.map(calls, fn %{id: id, name: n, args: a} ->
            %{"id" => id, "type" => "function",
              "function" => %{"name" => n, "arguments" => Jason.encode!(a)}}
          end)}

      %{role: :tool, tool_call_id: id, content: c} ->
        %{"role" => "tool", "tool_call_id" => id, "content" => c}

      %{role: role, content: c} ->
        %{"role" => to_string(role), "content" => c}
    end)
  end

  defp resolve_model(model_atom, opts) do
    case Keyword.fetch(opts, :model_string) do
      {:ok, str} ->
        str

      :error ->
        models = Application.get_env(:shem, :llm_models, %{})

        case Map.get(models, model_atom) do
          nil ->
            Logger.warning("Unknown LLM model atom #{inspect(model_atom)}, falling back to string")
            Atom.to_string(model_atom)

          str ->
            str
        end
    end
  end

  defp parse_response(
         %{"choices" => [%{"message" => message} | _], "usage" => usage},
         model,
         start_ms
       ) do
    content    = message["content"]
    raw_calls  = message["tool_calls"]
    tokens_used =
      Map.get(usage, "completion_tokens", 0) + Map.get(usage, "prompt_tokens", 0)
    latency_ms = System.monotonic_time(:millisecond) - start_ms

    tool_calls =
      if raw_calls do
        Enum.map(raw_calls, fn %{"id" => id, "function" => %{"name" => n, "arguments" => args_str}} ->
          %{id: id, name: n, args: Jason.decode!(args_str)}
        end)
      end

    {:ok,
     %Shem.LLM.Response{
       content:     content,
       tool_calls:  tool_calls,
       tokens_used: tokens_used,
       model:       model,
       latency_ms:  latency_ms
     }}
  end

  defp parse_response(raw_body, _model, _start_ms) do
    {:error, {:parse_error, raw_body}}
  end
end
```

- [ ] **Step 4: Run llama_cpp transport tests**

```bash
mix test test/shem/llm/middleware/llama_cpp_transport_test.exs 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/llm/middleware/llama_cpp_transport.ex \
        test/shem/llm/middleware/llama_cpp_transport_test.exs
git commit -m "feat: LlamaCppTransport — /v1/chat/completions, tools injection, tool_calls decoding"
```

---

## Task 8: `Agent.Server` — structured history entries

**Files:**
- Modify: `lib/shem/agent/server.ex`
- Modify: `test/shem/agent/server_test.exs`

- [ ] **Step 1: Write a failing test**

Identify the existing test setup in `test/shem/agent/server_test.exs` — it likely starts agents using `Shem.Agent.start_with_preset/2` or `Shem.Agent.start/2` with a stub/mock LLM. Add a test that verifies the EventLog receives the correct tool event after a tool call turn:

```elixir
  describe "tool call history — native format" do
    test "agent_tool_called event uses tool name from call.name (not call.tool)" do
      # Configure stub to return a native tool_call response on turn 1, done on turn 2
      tool_call = %{id: "call_test_1", name: "list_tools", args: %{}}
      turn1_resp = %Shem.LLM.Response{
        content: nil, tool_calls: [tool_call], tokens_used: 5, model: :default, latency_ms: 1
      }
      turn2_resp = %Shem.LLM.Response{
        content: "Done.", tool_calls: nil, tokens_used: 5, model: :default, latency_ms: 1
      }

      responses = [ok: turn1_resp, ok: turn2_resp]
      session_id = "ses_native_hist_#{:erlang.unique_integer([:positive])}"

      config = %Shem.Agent.Config{
        task:          "list available tools",
        system_prompt: "sys",
        model:         :default,
        max_turns:     5
      }

      Application.put_env(:shem, :llm_middleware, [
        {Shem.LLM.StubTransport, [responses: responses]}
      ])

      {:ok, agent} = Shem.Agent.start(config, session_id: session_id)
      {:ok, :done} = Shem.Agent.await(agent, 5_000)

      {:ok, events} = Shem.EventLog.events(session_id)
      tool_called = Enum.find(events, &(&1.type == :agent_tool_called))
      assert tool_called != nil
      assert tool_called.payload.tool == "list_tools"

      Application.delete_env(:shem, :llm_middleware)
    end
  end
```

> **Note on StubTransport:** Check how existing server tests configure the stub. If `StubTransport` accepts a `responses:` list for multi-turn sequences, use that. If it only accepts a single `response:`, check `lib/shem/llm/stub_transport.ex` and `lib/shem/llm/stub_transport/server.ex` for the available API before adapting the test.

- [ ] **Step 2: Run to verify the test fails**

```bash
mix test test/shem/agent/server_test.exs 2>&1 | tail -10
```

Expected: the new test fails — `execute_tool_calls` tries `call.tool` which doesn't exist on the new `%{id, name, args}` map; or `:agent_tool_called` event missing the `tool` key.

- [ ] **Step 3: Update `handle_info(:run_turn, ...)` in `lib/shem/agent/server.ex`**

Replace the `{:tool_calls, calls, raw}` clause in `handle_info`:

```elixir
          {:tool_calls, calls, raw} ->
            assistant_entry = %{
              role:       :assistant,
              content:    if(raw == "", do: nil, else: raw),
              tool_calls: calls
            }
            history = state.history ++ [assistant_entry]
            history = execute_tool_calls(calls, manifest, history, state.session_id)
            EventLog.append(state.session_id, :agent_turn_completed, %{
              turn: state.turn_count + 1,
              outcome: :tool_calls
            })
            new_state = %{state | history: history, turn_count: state.turn_count + 1}
            send(self(), :run_turn)
            {:noreply, new_state}
```

- [ ] **Step 4: Replace `execute_tool_calls/4` in `lib/shem/agent/server.ex`**

```elixir
  defp execute_tool_calls(calls, manifest, history, session_id) do
    Enum.reduce(calls, history, fn %{id: id, name: name, args: args} = call, acc ->
      EventLog.append(session_id, :agent_tool_called, %{tool: name, args: args})

      result_str =
        case ToolDispatch.execute(call, manifest) do
          {:ok, result}    -> result
          {:error, reason} -> "Error: #{reason}"
        end

      EventLog.append(session_id, :agent_tool_result, %{tool: name, result: result_str})
      acc ++ [%{role: :tool, tool_call_id: id, content: result_str}]
    end)
  end
```

- [ ] **Step 5: Run server tests**

```bash
mix test test/shem/agent/server_test.exs 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 6: Run the full suite**

```bash
mix test 2>&1 | tail -5
```

Expected: 0 failures. Test count is higher than before (new llama_cpp file + new tests across all modified files).

- [ ] **Step 7: Commit**

```bash
git add lib/shem/agent/server.ex test/shem/agent/server_test.exs
git commit -m "feat: Agent.Server — structured tool_calls history; tool_call_id on results"
```

---

## Self-Review Checklist

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| `tools: [tool_schema()] \| nil` on `Request` | Task 1 |
| `tool_calls: [tool_call()] \| nil` on `Response`; `content` nil-able | Task 1 |
| History entries gain `tool_calls` and `tool_call_id` | Task 8 |
| `parse_response/1` returns `%{id: nil, name, args}` | Task 3 |
| Inline JSON schemas on all 7 builtins | Task 2 |
| Permissive fallback schema for Lab/MCP tools | Task 2 |
| `ToolDispatch.execute/2` matches `:name` key | Task 2 |
| `build_request/4` populates `request.tools` from manifest | Task 3 |
| `build_messages/1` drops tool-header; handles new history shapes | Task 3 |
| `step/4` checks `response.tool_calls` first | Task 3 |
| OpenAI: `tools` array with `"function"` wrapper + `tool_choice` | Task 4 |
| OpenAI: `tool_calls` decoded, arguments JSON-decoded | Task 4 |
| OpenAI: assistant+tool_calls and tool+tool_call_id messages formatted | Task 4 |
| Anthropic: tools with `input_schema`, no wrapper | Task 5 |
| Anthropic: `tool_use` blocks decoded; text extracted alongside | Task 5 |
| Anthropic: assistant→content array; tool→user with tool_result block | Task 5 |
| Ollama: switched to `/api/chat` | Task 6 |
| Ollama: tools in OpenAI format; tool results omit tool_call_id on wire | Task 6 |
| Ollama: synthetic IDs generated | Task 6 |
| LlamaCpp: switched to `/v1/chat/completions` | Task 7 |
| LlamaCpp: tools injected; arguments JSON-decoded | Task 7 |
| `Agent.Server`: structured assistant entry with `tool_calls` | Task 8 |
| `Agent.Server`: tool result entries carry `tool_call_id` | Task 8 |
| `test/shem/llm/middleware/llama_cpp_transport_test.exs` created | Task 7 |

**No placeholders found.**

**Type consistency:**
- `tool_call` throughout: `%{id: String.t(), name: String.t(), args: map()}` — consistent across Request type alias, Response type alias, parse_response return, step/4 return, and Server history entries
- `tool_schema` in Request: `%{name, description, schema}` — `Map.take/2` in `build_request/4` picks exactly these three keys from the manifest; all four transport `format_tools` functions destructure exactly these three keys
- `build_messages/1` (arity 1) — all call sites in `build_request/4` call it with one argument; no stale two-argument calls remain
