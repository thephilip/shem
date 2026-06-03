# Phase 4: MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose Shem's core capabilities (code execution, graduation, tool registry, tool invocation) to Claude Code via an MCP-compliant HTTP/SSE server running as a persistent local daemon.

**Architecture:** `Shem.MCP.Server` (a Supervisor) is added to the application tree alongside the existing `Lab.Registry` and `EventLog`. It supervises `Shem.MCP.SessionRegistry` (GenServer tracking SSE sessions) and a Bandit HTTP server running the `Shem.MCP.Router` Plug pipeline. Clients connect via `GET /sse`, receive a session endpoint URL, then POST JSON-RPC messages to `/message?sessionId=<id>`. Responses are routed back through the SSE stream.

**Tech Stack:** Elixir/OTP, Bandit ~> 1.0, Plug ~> 1.16, Jason ~> 1.4, MCP JSON-RPC 2.0 over HTTP/SSE

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| Modify | `mix.exs` | add Bandit, Plug, Jason deps |
| Modify | `config/dev.exs` | `mcp_port: 4000` |
| Modify | `config/test.exs` | `mcp_port: 4001` |
| Modify | `lib/shem/tool.ex` | add `input_schema` field |
| Modify | `test/shem/tool_test.exs` | cover `input_schema` field |
| Create | `lib/shem/mcp/schema.ex` | validate args map against schema |
| Create | `test/shem/mcp/schema_test.exs` | |
| Create | `lib/shem/mcp/handlers/execute_code.ex` | MCP handler: scratch-pad execution |
| Create | `test/shem/mcp/handlers/execute_code_test.exs` | |
| Create | `lib/shem/mcp/handlers/graduate_tool.ex` | MCP handler: compile→test→register |
| Create | `test/shem/mcp/handlers/graduate_tool_test.exs` | |
| Create | `lib/shem/mcp/handlers/list_tools.ex` | MCP handler: browse registry |
| Create | `test/shem/mcp/handlers/list_tools_test.exs` | |
| Create | `lib/shem/mcp/handlers/invoke_tool.ex` | MCP handler: on-demand load + call |
| Create | `test/shem/mcp/handlers/invoke_tool_test.exs` | |
| Create | `lib/shem/mcp/router.ex` | Plug router: SSE + POST /message |
| Create | `test/shem/mcp/router_test.exs` | Plug.Test integration |
| Create | `lib/shem/mcp/session_registry.ex` | GenServer: SSE session tracking |
| Create | `test/shem/mcp/session_registry_test.exs` | |
| Create | `lib/shem/mcp/server.ex` | Supervisor: SessionRegistry + Bandit |
| Modify | `lib/shem/application.ex` | add `Shem.MCP.Server` to children |
| Modify | `lib/shem/tui/views/dashboard.ex` | MCP stat line |
| Modify | `lib/shem/tui/app.ex` | populate `mcp_client_count` in model |

---

## Task 1: Add dependencies and config

**Files:**
- Modify: `mix.exs`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Add deps to mix.exs**

In the `deps/0` function, add after `{:stream_data, ...}`:

```elixir
{:bandit, "~> 1.0"},
{:plug, "~> 1.16"},
{:jason, "~> 1.4"}
```

- [ ] **Step 2: Add MCP port to dev config**

`config/dev.exs` (create if it doesn't exist, otherwise append):

```elixir
import Config

config :shem, mcp_port: 4000
```

- [ ] **Step 3: Add MCP port to test config**

Append to `config/test.exs`:

```elixir
config :shem, mcp_port: 4001
```

- [ ] **Step 4: Fetch and compile deps**

```bash
mix deps.get && mix compile
```

Expected: clean compile, no warnings about missing modules.

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock config/dev.exs config/test.exs
git commit -m "chore: add Bandit, Plug, Jason deps; configure mcp_port"
```

---

## Task 2: Extend Shem.Tool with input_schema

**Files:**
- Modify: `lib/shem/tool.ex`
- Modify: `test/shem/tool_test.exs`

- [ ] **Step 1: Write the failing test**

In `test/shem/tool_test.exs`, add:

```elixir
test "defaults input_schema to empty map" do
  tool = %Shem.Tool{
    id: "foo",
    name: "Foo",
    module: Foo,
    source: "defmodule Foo do\nend",
    test_source: "",
    graduated_at: DateTime.utc_now()
  }
  assert tool.input_schema == %{}
end

test "accepts a non-empty input_schema" do
  tool = %Shem.Tool{
    id: "bar",
    name: "Bar",
    module: Bar,
    source: "defmodule Bar do\nend",
    test_source: "",
    graduated_at: DateTime.utc_now(),
    input_schema: %{"n" => %{"type" => "integer"}}
  }
  assert tool.input_schema == %{"n" => %{"type" => "integer"}}
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
mix test test/shem/tool_test.exs
```

Expected: fails with `KeyError` or struct mismatch on `input_schema`.

- [ ] **Step 3: Add the field to Shem.Tool**

In `lib/shem/tool.ex`, add `input_schema: %{}` to `defstruct` and `input_schema: map()` to the `@type`:

```elixir
defstruct [
  :id,
  :name,
  :module,
  :source,
  :test_source,
  :graduated_at,
  constraints: [],
  input_schema: %{},
  metadata: %{}
]

@type t :: %__MODULE__{
        id: String.t(),
        name: String.t(),
        module: atom(),
        source: String.t(),
        test_source: String.t(),
        constraints: [String.t()],
        input_schema: map(),
        graduated_at: DateTime.t(),
        metadata: map()
      }
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/tool_test.exs
```

Expected: all pass.

- [ ] **Step 5: Run full suite to check for regressions**

```bash
mix test
```

Expected: all existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/tool.ex test/shem/tool_test.exs
git commit -m "feat: add input_schema field to Shem.Tool"
```

---

## Task 3: Shem.MCP.Schema — input validation

**Files:**
- Create: `lib/shem/mcp/schema.ex`
- Create: `test/shem/mcp/schema_test.exs`

The schema map format: `%{"field_name" => %{"type" => "string"|"integer"|"boolean", "required" => true|false}}`. All fields are required unless `"required" => false` is explicitly set.

- [ ] **Step 1: Write the failing tests**

Create `test/shem/mcp/schema_test.exs`:

```elixir
defmodule Shem.MCP.SchemaTest do
  use ExUnit.Case, async: true

  alias Shem.MCP.Schema

  @schema %{
    "source" => %{"type" => "string"},
    "count"  => %{"type" => "integer"},
    "flag"   => %{"type" => "boolean", "required" => false}
  }

  test "valid args with all fields pass through" do
    args = %{"source" => "foo", "count" => 3, "flag" => true}
    assert {:ok, ^args} = Schema.validate(args, @schema)
  end

  test "valid args without optional field pass through" do
    args = %{"source" => "foo", "count" => 3}
    assert {:ok, ^args} = Schema.validate(args, @schema)
  end

  test "missing required field returns error" do
    args = %{"count" => 3}
    assert {:error, :invalid_args, details} = Schema.validate(args, @schema)
    assert details =~ "source"
  end

  test "wrong type returns error" do
    args = %{"source" => 42, "count" => 3}
    assert {:error, :invalid_args, details} = Schema.validate(args, @schema)
    assert details =~ "source"
  end

  test "empty schema accepts any args" do
    assert {:ok, %{"anything" => "goes"}} = Schema.validate(%{"anything" => "goes"}, %{})
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
mix test test/shem/mcp/schema_test.exs
```

Expected: `UndefinedFunctionError` — module doesn't exist yet.

- [ ] **Step 3: Implement Shem.MCP.Schema**

Create `lib/shem/mcp/schema.ex`:

```elixir
defmodule Shem.MCP.Schema do
  @type schema :: %{String.t() => %{String.t() => term()}}

  @spec validate(map(), schema()) :: {:ok, map()} | {:error, :invalid_args, String.t()}
  def validate(args, schema) when map_size(schema) == 0, do: {:ok, args}

  def validate(args, schema) do
    errors =
      Enum.flat_map(schema, fn {field, spec} ->
        required = Map.get(spec, "required", true)
        type = Map.get(spec, "type")

        cond do
          required and not Map.has_key?(args, field) ->
            ["#{field}: required field missing"]

          Map.has_key?(args, field) and not valid_type?(args[field], type) ->
            ["#{field}: expected #{type}, got #{inspect(args[field])}"]

          true ->
            []
        end
      end)

    if errors == [] do
      {:ok, args}
    else
      {:error, :invalid_args, Enum.join(errors, "; ")}
    end
  end

  defp valid_type?(v, "string"), do: is_binary(v)
  defp valid_type?(v, "integer"), do: is_integer(v)
  defp valid_type?(v, "boolean"), do: is_boolean(v)
  defp valid_type?(_, nil), do: true
  defp valid_type?(_, _), do: true
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/mcp/schema_test.exs
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/schema.ex test/shem/mcp/schema_test.exs
git commit -m "feat: Shem.MCP.Schema — input argument validation"
```

---

## Task 4: Handlers.ExecuteCode

**Files:**
- Create: `lib/shem/mcp/handlers/execute_code.ex`
- Create: `test/shem/mcp/handlers/execute_code_test.exs`

The handler receives validated args, delegates to `Lab.Executor`, and returns `{:ok, result}` or `{:error, kind, detail}`. The source must define a module with `run/0`; the executor calls it.

- [ ] **Step 1: Write the failing tests**

Create `test/shem/mcp/handlers/execute_code_test.exs`:

```elixir
defmodule Shem.MCP.Handlers.ExecuteCodeTest do
  use ExUnit.Case, async: false

  alias Shem.MCP.Handlers.ExecuteCode

  test "executes source that defines a module with run/0 and returns result" do
    source = """
    defmodule ExecTest1 do
      def run(), do: {:ok, 42}
    end
    """
    assert {:ok, {:ok, 42}} = ExecuteCode.call(%{"source" => source})
  end

  test "returns compile error for invalid Elixir source" do
    source = "this is not valid elixir !!!"
    assert {:error, :compile, reason} = ExecuteCode.call(%{"source" => source})
    assert is_binary(reason)
  end

  test "returns runtime error when run/0 raises" do
    source = """
    defmodule ExecTest2 do
      def run(), do: raise "boom"
    end
    """
    assert {:error, :runtime, _reason} = ExecuteCode.call(%{"source" => source})
  end

  test "returns missing_source error when source key is absent" do
    assert {:error, :invalid_args, _} = ExecuteCode.call(%{})
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
mix test test/shem/mcp/handlers/execute_code_test.exs
```

Expected: `UndefinedFunctionError`.

- [ ] **Step 3: Implement Handlers.ExecuteCode**

Create `lib/shem/mcp/handlers/execute_code.ex`:

```elixir
defmodule Shem.MCP.Handlers.ExecuteCode do
  alias Shem.Lab.Executor
  alias Shem.MCP.Schema

  @schema %{"source" => %{"type" => "string"}}

  @spec call(map()) :: {:ok, any()} | {:error, atom(), any()}
  def call(args) do
    with {:ok, valid} <- Schema.validate(args, @schema) do
      Executor.run(valid["source"], fn mod -> mod.run() end)
    end
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/mcp/handlers/execute_code_test.exs
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/handlers/execute_code.ex test/shem/mcp/handlers/execute_code_test.exs
git commit -m "feat: Handlers.ExecuteCode — scratch-pad code execution"
```

---

## Task 5: Handlers.GraduateTool

**Files:**
- Create: `lib/shem/mcp/handlers/graduate_tool.ex`
- Create: `test/shem/mcp/handlers/graduate_tool_test.exs`

Delegates to `GraduationGate.run/3`. The `input_schema` arg is optional (defaults to `%{}`).

- [ ] **Step 1: Write the failing tests**

Create `test/shem/mcp/handlers/graduate_tool_test.exs`:

```elixir
defmodule Shem.MCP.Handlers.GraduateToolTest do
  use ExUnit.Case, async: false

  alias Shem.MCP.Handlers.GraduateTool

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir, System.tmp_dir!())
    on_exit(fn -> File.rm_rf!(lab_dir) end)
    :ok
  end

  @source """
  defmodule GradHandlerTool1 do
    def run(args), do: {:ok, args}
  end
  """

  @test_source """
  defmodule GradHandlerTool1Test do
    def run do
      unless match?({:ok, _}, GradHandlerTool1.run(%{})), do: raise "broken"
      :ok
    end
  end
  """

  test "graduates a valid tool and returns the tool struct" do
    args = %{"source" => @source, "test_source" => @test_source}
    assert {:ok, tool} = GraduateTool.call(args)
    assert tool.id == "grad_handler_tool1"
    assert tool.module == GradHandlerTool1
  end

  test "accepts optional input_schema and stores it on the tool" do
    schema = %{"n" => %{"type" => "integer"}}
    args = %{"source" => @source, "test_source" => @test_source, "input_schema" => schema}
    assert {:ok, tool} = GraduateTool.call(args)
    assert tool.input_schema == schema
  end

  test "returns gate error when test source fails" do
    bad_test = """
    defmodule GradHandlerTool1Test do
      def run(), do: raise "deliberate failure"
    end
    """
    args = %{"source" => @source, "test_source" => bad_test}
    assert {:error, :gate, _} = GraduateTool.call(args)
  end

  test "returns invalid_args error when source is missing" do
    assert {:error, :invalid_args, _} = GraduateTool.call(%{"test_source" => @test_source})
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
mix test test/shem/mcp/handlers/graduate_tool_test.exs
```

Expected: `UndefinedFunctionError`.

- [ ] **Step 3: Implement Handlers.GraduateTool**

Create `lib/shem/mcp/handlers/graduate_tool.ex`:

```elixir
defmodule Shem.MCP.Handlers.GraduateTool do
  alias Shem.Lab.{GraduationGate, Registry}
  alias Shem.MCP.Schema

  @schema %{
    "source"       => %{"type" => "string"},
    "test_source"  => %{"type" => "string"},
    "input_schema" => %{"type" => "object", "required" => false}
  }

  @spec call(map()) :: {:ok, Shem.Tool.t()} | {:error, atom(), any()}
  def call(args) do
    with {:ok, valid} <- Schema.validate(args, @schema) do
      input_schema = Map.get(valid, "input_schema", %{})
      constraints  = Map.get(valid, "constraints", [])

      case GraduationGate.run(valid["source"], valid["test_source"], constraints) do
        {:ok, tool} ->
          updated = %{tool | input_schema: input_schema}
          :ok = Registry.register(updated)
          {:ok, updated}

        error ->
          error
      end
    end
  end
end
```

Note: `GraduationGate.run/3` already calls `Registry.register/1` internally. The handler re-registers to persist the `input_schema`. The second register overwrites the first (ETS insert is idempotent by key).

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/mcp/handlers/graduate_tool_test.exs
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/handlers/graduate_tool.ex test/shem/mcp/handlers/graduate_tool_test.exs
git commit -m "feat: Handlers.GraduateTool — MCP graduation gate entry point"
```

---

## Task 6: Handlers.ListTools

**Files:**
- Create: `lib/shem/mcp/handlers/list_tools.ex`
- Create: `test/shem/mcp/handlers/list_tools_test.exs`

Returns all graduated tools from `Lab.Registry` as a list of maps with `id`, `name`, and `input_schema`.

- [ ] **Step 1: Write the failing tests**

Create `test/shem/mcp/handlers/list_tools_test.exs`:

```elixir
defmodule Shem.MCP.Handlers.ListToolsTest do
  use ExUnit.Case, async: false

  alias Shem.MCP.Handlers.ListTools
  alias Shem.Lab.Registry
  alias Shem.Tool

  @tool %Tool{
    id: "lt_tool_1",
    name: "LtTool1",
    module: LtTool1,
    source: "defmodule LtTool1 do\n  def run(_args), do: :ok\nend",
    test_source: "",
    graduated_at: DateTime.utc_now(),
    input_schema: %{"x" => %{"type" => "integer"}}
  }

  test "returns empty list when no tools are registered" do
    assert {:ok, []} = ListTools.call(%{})
  end

  test "returns tool summaries for registered tools" do
    Registry.register(@tool)
    {:ok, tools} = ListTools.call(%{})
    found = Enum.find(tools, &(&1["id"] == "lt_tool_1"))
    assert found["name"] == "LtTool1"
    assert found["input_schema"] == %{"x" => %{"type" => "integer"}}
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
mix test test/shem/mcp/handlers/list_tools_test.exs
```

Expected: `UndefinedFunctionError`.

- [ ] **Step 3: Implement Handlers.ListTools**

Create `lib/shem/mcp/handlers/list_tools.ex`:

```elixir
defmodule Shem.MCP.Handlers.ListTools do
  alias Shem.Lab.Registry

  @spec call(map()) :: {:ok, [map()]}
  def call(_args) do
    tools =
      Registry.all()
      |> Enum.map(fn tool ->
        %{
          "id"           => tool.id,
          "name"         => tool.name,
          "input_schema" => tool.input_schema
        }
      end)

    {:ok, tools}
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/mcp/handlers/list_tools_test.exs
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/handlers/list_tools.ex test/shem/mcp/handlers/list_tools_test.exs
git commit -m "feat: Handlers.ListTools — browse the graduated tool registry"
```

---

## Task 7: Handlers.InvokeTool

**Files:**
- Create: `lib/shem/mcp/handlers/invoke_tool.ex`
- Create: `test/shem/mcp/handlers/invoke_tool_test.exs`

Resolves a tool by id, loads its module on demand (compiles from source if not already in VM), validates args against `input_schema`, calls `Module.run(args)`.

- [ ] **Step 1: Write the failing tests**

Create `test/shem/mcp/handlers/invoke_tool_test.exs`:

```elixir
defmodule Shem.MCP.Handlers.InvokeToolTest do
  use ExUnit.Case, async: false

  alias Shem.MCP.Handlers.InvokeTool
  alias Shem.Lab.Registry
  alias Shem.Tool

  @source """
  defmodule InvokeTarget1 do
    def run(args), do: {:ok, Map.get(args, "n", 0) * 2}
  end
  """

  @tool %Tool{
    id: "invoke_target_1",
    name: "InvokeTarget1",
    module: InvokeTarget1,
    source: @source,
    test_source: "",
    graduated_at: DateTime.utc_now(),
    input_schema: %{"n" => %{"type" => "integer"}}
  }

  setup do
    Registry.register(@tool)
    :ok
  end

  test "loads module and calls run/1 with args, returning result" do
    assert {:ok, {:ok, 84}} = InvokeTool.call(%{"id" => "invoke_target_1", "args" => %{"n" => 42}})
  end

  test "second call reuses already-loaded module" do
    InvokeTool.call(%{"id" => "invoke_target_1", "args" => %{"n" => 1}})
    assert {:ok, {:ok, 4}} = InvokeTool.call(%{"id" => "invoke_target_1", "args" => %{"n" => 2}})
  end

  test "returns not_found for unknown tool id" do
    assert {:error, :not_found} = InvokeTool.call(%{"id" => "no_such_tool", "args" => %{}})
  end

  test "returns invalid_args when required id field is missing" do
    assert {:error, :invalid_args, _} = InvokeTool.call(%{"args" => %{}})
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
mix test test/shem/mcp/handlers/invoke_tool_test.exs
```

Expected: `UndefinedFunctionError`.

- [ ] **Step 3: Implement Handlers.InvokeTool**

Create `lib/shem/mcp/handlers/invoke_tool.ex`:

```elixir
defmodule Shem.MCP.Handlers.InvokeTool do
  alias Shem.Lab.Registry
  alias Shem.MCP.Schema

  @schema %{
    "id"   => %{"type" => "string"},
    "args" => %{"required" => false}
  }

  @spec call(map()) :: {:ok, any()} | {:error, atom()} | {:error, atom(), any()}
  def call(params) do
    with {:ok, valid} <- Schema.validate(params, @schema),
         {:ok, tool}  <- Registry.lookup(valid["id"]),
         :ok          <- ensure_loaded(tool) do
      args = Map.get(valid, "args", %{})
      with {:ok, _} <- Schema.validate(args, tool.input_schema) do
        result = tool.module.run(args)
        {:ok, result}
      end
    end
  end

  defp ensure_loaded(%{module: module, source: source}) do
    case :code.is_loaded(module) do
      false ->
        case Code.compile_string(source) do
          [{^module, bytecode} | _] ->
            :code.load_binary(module, ~c"nofile", bytecode)
            :ok

          _ ->
            {:error, :load_failed}
        end

      _ ->
        :ok
    end
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/mcp/handlers/invoke_tool_test.exs
```

Expected: all pass.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/mcp/handlers/invoke_tool.ex test/shem/mcp/handlers/invoke_tool_test.exs
git commit -m "feat: Handlers.InvokeTool — on-demand module load and call"
```

---

## Task 8: Shem.MCP.SessionRegistry

**Files:**
- Create: `lib/shem/mcp/session_registry.ex`
- Create: `test/shem/mcp/session_registry_test.exs`

GenServer that tracks live SSE sessions (`session_id → pid`). Used by the Router to route JSON-RPC responses back to the correct SSE connection, and by the TUI to show client count.

- [ ] **Step 1: Write the failing tests**

Create `test/shem/mcp/session_registry_test.exs`:

```elixir
defmodule Shem.MCP.SessionRegistryTest do
  use ExUnit.Case, async: true

  alias Shem.MCP.SessionRegistry

  test "client_count starts at 0" do
    {:ok, pid} = start_supervised({SessionRegistry, name: :test_sr_1})
    assert 0 = GenServer.call(pid, :client_count)
  end

  test "register_session increments client_count" do
    {:ok, pid} = start_supervised({SessionRegistry, name: :test_sr_2})
    GenServer.call(pid, {:register, "sess-1", self()})
    assert 1 = GenServer.call(pid, :client_count)
  end

  test "unregister_session decrements client_count" do
    {:ok, pid} = start_supervised({SessionRegistry, name: :test_sr_3})
    GenServer.call(pid, {:register, "sess-1", self()})
    GenServer.call(pid, {:unregister, "sess-1"})
    assert 0 = GenServer.call(pid, :client_count)
  end

  test "send_to_session delivers a message to the registered pid" do
    {:ok, pid} = start_supervised({SessionRegistry, name: :test_sr_4})
    GenServer.call(pid, {:register, "sess-1", self()})
    GenServer.call(pid, {:send, "sess-1", %{"hello" => "world"}})
    assert_receive {:mcp_response, %{"hello" => "world"}}
  end

  test "send_to_session returns error for unknown session" do
    {:ok, pid} = start_supervised({SessionRegistry, name: :test_sr_5})
    assert {:error, :not_found} = GenServer.call(pid, {:send, "ghost", %{}})
  end

  test "dead session processes are cleaned up automatically" do
    {:ok, pid} = start_supervised({SessionRegistry, name: :test_sr_6})
    session_pid = spawn(fn -> receive do: (:stop -> :ok) end)
    GenServer.call(pid, {:register, "sess-1", session_pid})
    send(session_pid, :stop)
    Process.sleep(20)
    assert 0 = GenServer.call(pid, :client_count)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
mix test test/shem/mcp/session_registry_test.exs
```

Expected: `UndefinedFunctionError`.

- [ ] **Step 3: Implement SessionRegistry**

Create `lib/shem/mcp/session_registry.ex`:

```elixir
defmodule Shem.MCP.SessionRegistry do
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def client_count(server \\ __MODULE__),
    do: GenServer.call(server, :client_count)

  @impl true
  def init(:ok), do: {:ok, %{sessions: %{}, monitors: %{}}}

  @impl true
  def handle_call({:register, session_id, pid}, _from, state) do
    ref = Process.monitor(pid)
    state = put_in(state, [:sessions, session_id], pid)
    state = put_in(state, [:monitors, ref], session_id)
    {:reply, :ok, state}
  end

  def handle_call({:unregister, session_id}, _from, state) do
    {:reply, :ok, drop_session(state, session_id)}
  end

  def handle_call({:send, session_id, data}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil -> {:reply, {:error, :not_found}, state}
      pid ->
        send(pid, {:mcp_response, data})
        {:reply, :ok, state}
    end
  end

  def handle_call(:client_count, _from, state),
    do: {:reply, map_size(state.sessions), state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _}         -> {:noreply, state}
      {session_id, monitors} ->
        {:noreply, drop_session(%{state | monitors: monitors}, session_id)}
    end
  end

  defp drop_session(state, session_id),
    do: update_in(state, [:sessions], &Map.delete(&1, session_id))
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/mcp/session_registry_test.exs
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/session_registry.ex test/shem/mcp/session_registry_test.exs
git commit -m "feat: Shem.MCP.SessionRegistry — SSE session tracking"
```

---

## Task 9: Shem.MCP.Router — Plug router

**Files:**
- Create: `lib/shem/mcp/router.ex`
- Create: `test/shem/mcp/router_test.exs`

Handles `GET /sse` (long-lived SSE connection) and `POST /message` (JSON-RPC dispatch). The MCP protocol uses JSON-RPC 2.0 with methods `initialize`, `initialized` (notification), `ping`, `tools/list`, and `tools/call`.

- [ ] **Step 1: Write the failing tests**

Create `test/shem/mcp/router_test.exs`:

```elixir
defmodule Shem.MCP.RouterTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Shem.MCP.Router

  @opts Router.init([])

  defp post_rpc(method, params, id \\ 1) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id})
    conn(:post, "/message", body)
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp decode_response(conn) do
    Jason.decode!(conn.resp_body)
  end

  test "POST /message initialize returns server info" do
    conn = post_rpc("initialize", %{
      "protocolVersion" => "2024-11-05",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "test", "version" => "0.0.1"}
    })
    assert conn.status == 200
    resp = decode_response(conn)
    assert resp["result"]["serverInfo"]["name"] == "shem"
    assert resp["id"] == 1
  end

  test "POST /message tools/list returns the four Shem tools" do
    conn = post_rpc("tools/list", %{})
    assert conn.status == 200
    resp = decode_response(conn)
    names = Enum.map(resp["result"]["tools"], & &1["name"])
    assert "execute_code" in names
    assert "graduate_tool" in names
    assert "list_tools" in names
    assert "invoke_tool" in names
  end

  test "POST /message tools/call execute_code returns result" do
    source = """
    defmodule RouterExecTest1 do
      def run(), do: "hello from exec"
    end
    """
    conn = post_rpc("tools/call", %{"name" => "execute_code", "arguments" => %{"source" => source}})
    assert conn.status == 200
    resp = decode_response(conn)
    assert [%{"type" => "text", "text" => text}] = resp["result"]["content"]
    assert text =~ "hello from exec"
  end

  test "POST /message unknown method returns method-not-found error" do
    conn = post_rpc("unknown/method", %{})
    assert conn.status == 200
    resp = decode_response(conn)
    assert resp["error"]["code"] == -32601
  end

  test "POST /message with invalid JSON returns parse error" do
    conn = conn(:post, "/message", "not json {{{")
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
    assert conn.status == 400
  end

  test "POST /message notification (no id) returns 204 no content" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}})
    conn = conn(:post, "/message", body)
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
    assert conn.status == 204
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
mix test test/shem/mcp/router_test.exs
```

Expected: `UndefinedFunctionError` on `Shem.MCP.Router`.

- [ ] **Step 3: Implement Shem.MCP.Router**

Create `lib/shem/mcp/router.ex`:

```elixir
defmodule Shem.MCP.Router do
  use Plug.Router

  alias Shem.MCP.Handlers.{ExecuteCode, GraduateTool, ListTools, InvokeTool}

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["*/*"]

  plug :match
  plug :dispatch

  get "/sse" do
    session_id = generate_session_id()
    port = Application.get_env(:shem, :mcp_port, 4000)
    endpoint_url = "http://localhost:#{port}/message?sessionId=#{session_id}"

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    Shem.MCP.SessionRegistry.register_sse(session_id, self())

    case chunk(conn, "event: endpoint\ndata: #{endpoint_url}\n\n") do
      {:ok, conn} -> sse_loop(conn, session_id)
      {:error, _} -> unregister(session_id, conn)
    end
  end

  post "/message" do
    session_id = conn.query_params["sessionId"]

    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        send_resp(conn, 400, Jason.encode!(%{"error" => "parse error"}))

      params when is_map(params) ->
        handle_rpc(conn, params, session_id)

      _ ->
        send_resp(conn, 400, Jason.encode!(%{"error" => "parse error"}))
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # ── JSON-RPC dispatch ──────────────────────────────────────────────────────

  defp handle_rpc(conn, params, session_id) do
    id     = Map.get(params, "id")
    method = Map.get(params, "method")
    args   = Map.get(params, "params", %{})

    # Notifications (no id) — acknowledge silently
    if is_nil(id) do
      send_resp(conn, 204, "")
    else
      result = dispatch_method(method, args)
      response = build_response(id, result)
      send_or_sse(conn, session_id, response)
    end
  end

  defp dispatch_method("initialize", _args) do
    {:ok, %{
      "protocolVersion" => "2024-11-05",
      "capabilities"    => %{"tools" => %{}},
      "serverInfo"      => %{"name" => "shem", "version" => "0.1.0"}
    }}
  end

  defp dispatch_method("ping", _args), do: {:ok, %{}}

  defp dispatch_method("tools/list", _args) do
    {:ok, %{"tools" => builtin_tool_descriptors()}}
  end

  defp dispatch_method("tools/call", %{"name" => name, "arguments" => arguments}) do
    case call_tool(name, arguments) do
      {:ok, result}        -> {:ok, %{"content" => [%{"type" => "text", "text" => inspect(result)}]}}
      {:error, kind, detail} -> {:error, -32602, "#{kind}: #{inspect(detail)}"}
      {:error, kind}       -> {:error, -32602, inspect(kind)}
    end
  end

  defp dispatch_method("tools/call", _), do: {:error, -32602, "missing name or arguments"}
  defp dispatch_method(_, _),            do: {:error, -32601, "Method not found"}

  defp call_tool("execute_code",  args), do: ExecuteCode.call(args)
  defp call_tool("graduate_tool", args), do: GraduateTool.call(args)
  defp call_tool("list_tools",    args), do: ListTools.call(args)
  defp call_tool("invoke_tool",   args), do: InvokeTool.call(args)
  defp call_tool(_, _),                  do: {:error, :not_found}

  defp build_response(id, {:ok, result}),
    do: %{"jsonrpc" => "2.0", "result" => result, "id" => id}

  defp build_response(id, {:error, code, message}),
    do: %{"jsonrpc" => "2.0", "error" => %{"code" => code, "message" => message}, "id" => id}

  # ── SSE helpers ────────────────────────────────────────────────────────────

  defp send_or_sse(conn, nil, response) do
    send_resp(conn, 200, Jason.encode!(response))
  end

  defp send_or_sse(conn, session_id, response) do
    Shem.MCP.SessionRegistry.send_to_session(session_id, response)
    send_resp(conn, 202, "")
  end

  defp sse_loop(conn, session_id) do
    receive do
      {:mcp_response, data} ->
        payload = "data: #{Jason.encode!(data)}\n\n"
        case chunk(conn, payload) do
          {:ok, conn} -> sse_loop(conn, session_id)
          {:error, _} -> unregister(session_id, conn)
        end

      :close ->
        unregister(session_id, conn)
    after
      30_000 ->
        case chunk(conn, ": ping\n\n") do
          {:ok, conn} -> sse_loop(conn, session_id)
          {:error, _} -> unregister(session_id, conn)
        end
    end
  end

  defp unregister(session_id, conn) do
    Shem.MCP.SessionRegistry.unregister_session(session_id)
    conn
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  # ── Built-in tool descriptors ──────────────────────────────────────────────

  defp builtin_tool_descriptors do
    [
      %{
        "name"        => "execute_code",
        "description" => "Compile and run Elixir source in a scratch context. Source must define a module with run/0. Nothing persists.",
        "inputSchema" => %{
          "type"       => "object",
          "properties" => %{"source" => %{"type" => "string", "description" => "Elixir source code"}},
          "required"   => ["source"]
        }
      },
      %{
        "name"        => "graduate_tool",
        "description" => "Atomically compile, test, and register a tool. Fails with details if tests fail.",
        "inputSchema" => %{
          "type"       => "object",
          "properties" => %{
            "source"       => %{"type" => "string", "description" => "Tool implementation source"},
            "test_source"  => %{"type" => "string", "description" => "Test module source defining run/0"},
            "input_schema" => %{"type" => "object", "description" => "JSON Schema for the tool's run/1 args (optional)"}
          },
          "required" => ["source", "test_source"]
        }
      },
      %{
        "name"        => "list_tools",
        "description" => "List all graduated tools in the registry.",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name"        => "invoke_tool",
        "description" => "Invoke a graduated tool by id, passing args to its run/1 function.",
        "inputSchema" => %{
          "type"       => "object",
          "properties" => %{
            "id"   => %{"type" => "string", "description" => "Tool id from list_tools"},
            "args" => %{"type" => "object", "description" => "Arguments matching the tool's input_schema"}
          },
          "required" => ["id"]
        }
      }
    ]
  end
end
```

Also add `register_sse/2` and `unregister_session/1` public API to `SessionRegistry`:

In `lib/shem/mcp/session_registry.ex`, add after `start_link`:

```elixir
def register_sse(session_id, pid, server \\ __MODULE__),
  do: GenServer.call(server, {:register, session_id, pid})

def unregister_session(session_id, server \\ __MODULE__),
  do: GenServer.call(server, {:unregister, session_id})

def send_to_session(session_id, data, server \\ __MODULE__),
  do: GenServer.call(server, {:send, session_id, data})
```

- [ ] **Step 4: Run tests**

```bash
mix test test/shem/mcp/router_test.exs
```

Expected: all pass. (The `GET /sse` test is skipped — SSE long-connections are not tested via Plug.Test; covered by manual smoke test in Task 12.)

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shem/mcp/router.ex lib/shem/mcp/session_registry.ex test/shem/mcp/router_test.exs
git commit -m "feat: Shem.MCP.Router — Plug router with JSON-RPC dispatch and SSE"
```

---

## Task 10: Shem.MCP.Server — supervisor, wire into Application

**Files:**
- Create: `lib/shem/mcp/server.ex`
- Modify: `lib/shem/application.ex`

`Shem.MCP.Server` is a Supervisor that starts `SessionRegistry` and `Bandit`.

- [ ] **Step 1: Create Shem.MCP.Server**

Create `lib/shem/mcp/server.ex`:

```elixir
defmodule Shem.MCP.Server do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    port = Application.get_env(:shem, :mcp_port, 4000)

    children = [
      Shem.MCP.SessionRegistry,
      {Bandit, plug: Shem.MCP.Router, port: port, ip: {127, 0, 0, 1}, scheme: :http}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

- [ ] **Step 2: Add to Application supervision tree**

In `lib/shem/application.ex`, add `Shem.MCP.Server` after `Shem.Lab.Registry`:

```elixir
children =
  [
    {Registry, keys: :unique, name: Shem.Registry},
    Shem.AgentSupervisor,
    Shem.EventLog,
    {Task.Supervisor, name: Shem.Lab.TaskSupervisor},
    Shem.Lab.Registry,
    Shem.MCP.Server
  ] ++ tui_children()
```

- [ ] **Step 3: Verify it starts**

```bash
mix run --no-halt
```

Expected: Shem starts cleanly. No crash. You should see the TUI (or a clean startup log if TUI is disabled). MCP server is listening on `localhost:4000`.

In a second terminal, verify the server responds:

```bash
curl -s -X POST http://localhost:4000/message \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}},"id":1}'
```

Expected: JSON response with `"serverInfo": {"name": "shem", ...}`.

Stop Shem with `Ctrl+C`.

- [ ] **Step 4: Run full test suite**

```bash
mix test
```

Expected: all pass. (The MCP server is NOT started in test — there's no `start_mcp: true` guard yet. Add one now.)

If the `Shem.MCP.Server` starts in test and conflicts, add a guard in `application.ex`:

```elixir
defp mcp_children do
  if Application.get_env(:shem, :start_mcp, true) do
    [Shem.MCP.Server]
  else
    []
  end
end
```

And update the children list:

```elixir
children =
  [
    {Registry, keys: :unique, name: Shem.Registry},
    Shem.AgentSupervisor,
    Shem.EventLog,
    {Task.Supervisor, name: Shem.Lab.TaskSupervisor},
    Shem.Lab.Registry
  ] ++ mcp_children() ++ tui_children()
```

And in `config/test.exs`, add:

```elixir
config :shem, start_mcp: false
```

Re-run:

```bash
mix test
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/mcp/server.ex lib/shem/application.ex config/test.exs
git commit -m "feat: Shem.MCP.Server supervisor; wire into Application supervision tree"
```

---

## Task 11: TUI dashboard — MCP stat line

**Files:**
- Modify: `lib/shem/tui/app.ex`
- Modify: `lib/shem/tui/views/dashboard.ex`

Add `mcp_client_count` to the TUI model, populated on tick, displayed in the Lab Status panel.

- [ ] **Step 1: Update TUI model in App**

In `lib/shem/tui/app.ex`, update `init/1` to add `mcp_client_count: 0`:

```elixir
@impl true
def init(_context) do
  %{
    mode: :dashboard,
    command_buffer: "",
    paused: false,
    event_log_stats: %{sessions: 0, total_events: 0},
    tool_count: 0,
    mcp_client_count: 0
  }
end
```

Update the `:tick` handler in `update/2`:

```elixir
:tick ->
  %{model |
    event_log_stats: safe_stats(),
    tool_count: safe_tool_count(),
    mcp_client_count: safe_mcp_count()
  }
```

Add `safe_mcp_count/0` private function at the bottom of the module:

```elixir
defp safe_mcp_count do
  try do
    Shem.MCP.SessionRegistry.client_count()
  catch
    :exit, _ -> 0
  end
end
```

- [ ] **Step 2: Update Dashboard view**

In `lib/shem/tui/views/dashboard.ex`, in the Lab Status panel, add after the `Tools graduated` line:

```elixir
label(
  content: "MCP: localhost:#{Application.get_env(:shem, :mcp_port, 4000)} — #{model.mcp_client_count} connected",
  color: color(:cyan)
)
```

- [ ] **Step 3: Run TUI tests**

```bash
mix test test/shem/tui/
```

Expected: all pass. (Dashboard test may need updating if it checks exact label content — update the expected strings to include the new MCP line.)

- [ ] **Step 4: Run full suite**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shem/tui/app.ex lib/shem/tui/views/dashboard.ex
git commit -m "feat: TUI dashboard shows MCP server address and client count"
```

---

## Task 12: Manual smoke test

This task is not automated. Run it by hand after completing Tasks 1–11.

- [ ] **Step 1: Start Shem**

```bash
mix run --no-halt
```

Verify TUI shows:
- `Tools graduated: 0`
- `MCP: localhost:4000 — 0 connected`

- [ ] **Step 2: Test initialize**

In a second terminal:

```bash
curl -s -X POST http://localhost:4000/message \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}},"id":1}' \
  | python3 -m json.tool
```

Expected: `result.serverInfo.name == "shem"`.

- [ ] **Step 3: Test tools/list**

```bash
curl -s -X POST http://localhost:4000/message \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}' \
  | python3 -m json.tool
```

Expected: four tools listed: `execute_code`, `graduate_tool`, `list_tools`, `invoke_tool`.

- [ ] **Step 4: Test execute_code**

```bash
curl -s -X POST http://localhost:4000/message \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","method":"tools/call",
    "params":{"name":"execute_code","arguments":{"source":"defmodule SmokeEval do\n  def run(), do: 42\nend"}},
    "id":3
  }' | python3 -m json.tool
```

Expected: `result.content[0].text == "42"`.

- [ ] **Step 5: Test graduate_tool and invoke_tool**

```bash
curl -s -X POST http://localhost:4000/message \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","method":"tools/call",
    "params":{"name":"graduate_tool","arguments":{
      "source":"defmodule SmokeDouble do\n  def run(args), do: {:ok, args[\"n\"] * 2}\nend",
      "test_source":"defmodule SmokeDoubleTest do\n  def run do\n    unless match?({:ok, _}, SmokeDouble.run(%{\"n\" => 3})), do: raise \"broken\"\n    :ok\n  end\nend",
      "input_schema": {"n": {"type": "integer"}}
    }},
    "id":4
  }' | python3 -m json.tool
```

Expected: `result.content[0].text` contains the tool id (e.g. `"smoke_double"`).

```bash
curl -s -X POST http://localhost:4000/message \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","method":"tools/call",
    "params":{"name":"invoke_tool","arguments":{"id":"smoke_double","args":{"n":21}}},
    "id":5
  }' | python3 -m json.tool
```

Expected: `result.content[0].text == "{:ok, 42}"`.

- [ ] **Step 6: Verify TUI shows 0 MCP clients (no SSE connection yet)**

TUI should still show `MCP: localhost:4000 — 0 connected` since we used plain HTTP POST without SSE.

- [ ] **Step 7: Final commit**

```bash
git add -p  # stage any remaining changes
git commit -m "feat: Phase 4 MCP server complete — smoke test passed"
```
