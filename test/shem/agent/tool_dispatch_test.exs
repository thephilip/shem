# test/shem/agent/tool_dispatch_test.exs
defmodule Shem.Agent.ToolDispatchTest do
  use ExUnit.Case, async: false

  alias Shem.Agent.{Config, ToolDispatch}
  alias Shem.Lab.Registry
  alias Shem.LLM.{Response, StubTransport}

  @config %Config{task: "t", system_prompt: "s"}

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir)
    on_exit(fn ->
      File.rm_rf!(lab_dir)
      Registry.flush()
      Shem.Trust.Store.flush()
    end)
    :ok
  end

  describe "build_manifest/1" do
    test "includes all three built-ins" do
      manifest = ToolDispatch.build_manifest(@config)
      names = Enum.map(manifest, & &1.name)
      assert "write_tool" in names
      assert "run_code" in names
      assert "list_tools" in names
    end

    test "built-in entries have :builtin source" do
      manifest = ToolDispatch.build_manifest(@config)
      builtins = Enum.filter(manifest, &(&1.source == :builtin))
      assert length(builtins) == 12
    end

    test "includes graduated Lab tools with {:lab, id} source" do
      source = """
      defmodule DispatchTool1 do
        def run(_args), do: :ok
      end
      """
      test_src = """
      defmodule DispatchTool1Test do
        def run, do: :ok
      end
      """
      {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
      manifest = ToolDispatch.build_manifest(@config)
      assert Enum.any?(manifest, &(&1.source == {:lab, tool.id}))
    end

    test "allow-list filters builtins to only listed names (plus list_tools always present)" do
      config = %Config{task: "t", system_prompt: "s", tools: ["read_file", "list_dir"]}
      manifest = ToolDispatch.build_manifest(config)
      names = Enum.map(manifest, & &1.name)
      assert "read_file" in names
      assert "list_dir" in names
      # list_tools is always injected regardless of allow-list — it is a pure meta-capability
      assert "list_tools" in names
      refute "write_file" in names
      refute "shell" in names
      refute "run_code" in names
      refute "write_tool" in names
    end

    test "allow-list includes or excludes Lab tools based on their name" do
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

    test "builtin tools have trust: :builtin" do
      config = %Config{task: "t", system_prompt: "s", tools: []}
      manifest = ToolDispatch.build_manifest(config)
      builtin = Enum.find(manifest, &(&1.name == "read_file"))
      assert builtin.trust == :builtin
    end

    test "unrated Lab tool has trust: :unrated" do
      source = """
      defmodule TrustUnratedTool do
        def run(_args), do: :ok
      end
      """
      test_src = """
      defmodule TrustUnratedToolTest do
        def run, do: :ok
      end
      """
      {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
      Shem.Trust.Store.flush()

      config = %Config{task: "t", system_prompt: "s", tools: []}
      manifest = ToolDispatch.build_manifest(config)
      entry = Enum.find(manifest, &(&1.name == tool.name))
      assert entry.trust == :unrated
    end

    test "rated Lab tool has correct trust band" do
      source = """
      defmodule TrustRatedTool do
        def run(_args), do: :ok
      end
      """
      test_src = """
      defmodule TrustRatedToolTest do
        def run, do: :ok
      end
      """
      {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
      Shem.Trust.Store.record(tool.id, %{outcome: :clean, rounds: 1})

      config = %Config{task: "t", system_prompt: "s", tools: []}
      manifest = ToolDispatch.build_manifest(config)
      entry = Enum.find(manifest, &(&1.name == tool.name))
      assert entry.trust == :high
    end

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
        def run, do: :ok
      end
      """
      {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
      config = %Config{task: "t", system_prompt: "s", tools: []}
      manifest = ToolDispatch.build_manifest(config)
      entry = Enum.find(manifest, &(&1.name == tool.name))
      assert entry.schema == %{type: "object", properties: %{}, required: []}
    end

    test "Lab tools surface schema from metadata when toolsmith provided one" do
      source = """
      defmodule SchemaProvidedTool do
        def run(%{"x" => x}), do: x
      end
      """
      test_src = """
      defmodule SchemaProvidedToolTest do
        def run, do: :ok
      end
      """
      provided_schema = %{"type" => "object", "properties" => %{"x" => %{"type" => "integer"}}, "required" => ["x"]}
      {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src, schema: provided_schema)
      config = %Config{task: "t", system_prompt: "s", tools: []}
      manifest = ToolDispatch.build_manifest(config)
      entry = Enum.find(manifest, &(&1.name == tool.name))
      assert entry.schema == provided_schema
    end

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
  end

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
        "source"      => source,
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

  describe "execute/2 — list_tools built-in" do
    test "returns {:ok, formatted string} listing manifest tools" do
      manifest = [%{name: "foo", description: "does foo", source: :builtin}]
      assert {:ok, result} = ToolDispatch.execute(%{name: "list_tools", args: %{}}, manifest)
      assert result =~ "foo"
      assert result =~ "does foo"
    end
  end

  describe "execute/2 — run_code built-in" do
    test "returns {:ok, result} for valid source with run/0" do
      source = """
      defmodule RunCodeTest1 do
        def run, do: 1 + 1
      end
      """
      manifest = [%{name: "run_code", description: "run", source: :builtin}]
      assert {:ok, "2"} = ToolDispatch.execute(%{name: "run_code", args: %{"source" => source}}, manifest)
    end

    test "returns {:error, msg} for source with compile error" do
      manifest = [%{name: "run_code", description: "run", source: :builtin}]
      assert {:error, msg} =
               ToolDispatch.execute(
                 %{name: "run_code", args: %{"source" => "this is not valid elixir !!!"}},
                 manifest
               )
      assert msg =~ "compile error"
    end
  end

  describe "execute/2 — write_tool built-in" do
    test "returns {:ok, 'graduated: name'} on valid source and tests" do
      source = """
      defmodule WriteToolTarget1 do
        def run(_args), do: :written
      end
      """
      test_src = """
      defmodule WriteToolTarget1Test do
        def run, do: :ok
      end
      """
      manifest = [%{name: "write_tool", description: "write", source: :builtin}]
      assert {:ok, "graduated: WriteToolTarget1"} =
               ToolDispatch.execute(
                 %{name: "write_tool", args: %{"source" => source, "test_source" => test_src}},
                 manifest
               )
    end

    test "returns {:error, msg} when test fails" do
      source = """
      defmodule WriteToolTarget2 do
        def run(_args), do: :ok
      end
      """
      test_src = """
      defmodule WriteToolTarget2Test do
        def run, do: raise "intentional failure"
      end
      """
      manifest = [%{name: "write_tool", description: "write", source: :builtin}]
      assert {:error, msg} =
               ToolDispatch.execute(
                 %{name: "write_tool", args: %{"source" => source, "test_source" => test_src}},
                 manifest
               )
      assert msg =~ "test failed"
    end
  end

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
               ToolDispatch.execute(%{name: tool.name, args: %{"x" => 1}}, manifest)
    end
  end

  describe "execute/2 — unknown tool" do
    test "returns {:error, 'unknown tool: name'} when not in manifest" do
      assert {:error, "unknown tool: ghost"} =
               ToolDispatch.execute(%{name: "ghost", args: %{}}, [])
    end
  end

  describe "read_file built-in" do
    test "returns file contents on success" do
      path = Path.join(System.tmp_dir!(), "shem_test_read_#{System.unique_integer([:positive])}.txt")
      File.write!(path, "hello world")
      on_exit(fn -> File.rm(path) end)

      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, "hello world"} = ToolDispatch.execute(%{name: "read_file", args: %{"path" => path}}, manifest)
    end

    test "returns error for missing file" do
      manifest = ToolDispatch.build_manifest(@config)
      result = ToolDispatch.execute(%{name: "read_file", args: %{"path" => "/nonexistent/path/xyz"}}, manifest)
      assert match?({:error, _}, result)
    end
  end

  describe "write_file built-in" do
    test "writes file and returns byte count message" do
      path = Path.join(System.tmp_dir!(), "shem_test_write_#{System.unique_integer([:positive])}.txt")
      on_exit(fn -> File.rm(path) end)

      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, msg} = ToolDispatch.execute(%{name: "write_file", args: %{"path" => path, "content" => "test content"}}, manifest)
      assert String.contains?(msg, "bytes")
      assert File.read!(path) == "test content"
    end

    test "returns error for unwritable path" do
      manifest = ToolDispatch.build_manifest(@config)
      result = ToolDispatch.execute(%{name: "write_file", args: %{"path" => "/nonexistent_dir/file.txt", "content" => "x"}}, manifest)
      assert match?({:error, _}, result)
    end
  end

  describe "list_dir built-in" do
    test "returns newline-joined directory entries" do
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, entries} = ToolDispatch.execute(%{name: "list_dir", args: %{"path" => "lib/shem"}}, manifest)
      assert String.contains?(entries, "agent")
      assert String.contains?(entries, "event_log.ex")
    end

    test "returns error for missing directory" do
      manifest = ToolDispatch.build_manifest(@config)
      result = ToolDispatch.execute(%{name: "list_dir", args: %{"path" => "/nonexistent_xyz"}}, manifest)
      assert match?({:error, _}, result)
    end
  end

  describe "shell built-in" do
    test "returns stdout for successful command" do
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, output} = ToolDispatch.execute(%{name: "shell", args: %{"cmd" => "echo hello"}}, manifest)
      assert String.trim(output) == "hello"
    end

    test "returns exit code error for failing command" do
      manifest = ToolDispatch.build_manifest(@config)
      result = ToolDispatch.execute(%{name: "shell", args: %{"cmd" => "exit 1"}}, manifest)
      assert match?({:error, "exit 1:" <> _}, result)
    end

    test "returns timeout error when exceeded" do
      manifest = ToolDispatch.build_manifest(@config)
      result = ToolDispatch.execute(%{name: "shell", args: %{"cmd" => "sleep 10", "timeout_ms" => 100}}, manifest)
      assert match?({:error, "timeout after 100ms"}, result)
    end

    test "routes through Executor.run_shell/3 (Container backend reachable via process override)" do
      # Set Container backend; nil container_runtime_bin returns a known error,
      # confirming the call went through run_shell/3 to Backend.Container, not System.cmd directly
      old = Process.get(:shem_executor_backend)
      old_runtime_bin = Application.get_env(:shem, :container_runtime_bin)

      on_exit(fn ->
        if old, do: Process.put(:shem_executor_backend, old),
        else: Process.delete(:shem_executor_backend)
        if old_runtime_bin, do: Application.put_env(:shem, :container_runtime_bin, old_runtime_bin),
        else: Application.delete_env(:shem, :container_runtime_bin)
      end)

      Process.put(:shem_executor_backend, Shem.Lab.Executor.Backend.Container)
      Application.put_env(:shem, :container_runtime_bin, nil)

      manifest = ToolDispatch.build_manifest(@config)
      result = ToolDispatch.execute(%{name: "shell", args: %{"cmd" => "echo hi"}}, manifest)

      assert {:error, "no container runtime available" <> _} = result
    end
  end

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

    test "returns error when key is missing" do
      manifest = ToolDispatch.build_manifest(@config)
      assert {:error, "recall requires key"} =
        ToolDispatch.execute(%{name: "recall", args: %{}}, manifest)
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

    test "returns error when key is missing" do
      manifest = ToolDispatch.build_manifest(@config)
      assert {:error, "forget requires key"} =
        ToolDispatch.execute(%{name: "forget", args: %{}}, manifest)
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

  describe "spawn_agent built-in" do
    setup do
      Shem.LLM.BudgetServer.reset()
      StubTransport.Server.reset()
      :ok
    end

    test "returns sub-agent final answer on success" do
      StubTransport.Server.push_response(
        {:ok, %Response{content: "Sub-task complete.", tokens_used: 5, model: :default, latency_ms: 1}}
      )
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, "Sub-task complete."} =
        ToolDispatch.execute(
          %{name: "spawn_agent", args: %{"task" => "do the sub-task", "preset" => "general"}},
          manifest
        )
    end

    test "returns error result when preset does not exist" do
      manifest = ToolDispatch.build_manifest(@config)
      assert {:error, reason} =
        ToolDispatch.execute(
          %{name: "spawn_agent", args: %{"task" => "do something", "preset" => "no_such_preset"}},
          manifest
        )
      assert String.contains?(reason, "sub-agent failed")
    end

    test "returns depth limit error without starting an agent" do
      Process.put(:spawn_agent_depth, 2)
      on_exit(fn -> Process.delete(:spawn_agent_depth) end)
      manifest = ToolDispatch.build_manifest(@config)
      assert {:error, "spawn_agent depth limit reached (2)"} =
        ToolDispatch.execute(
          %{name: "spawn_agent", args: %{"task" => "do something"}},
          manifest
        )
    end

    test "defaults preset to general when omitted" do
      StubTransport.Server.push_response(
        {:ok, %Response{content: "Done with default preset.", tokens_used: 5, model: :default, latency_ms: 1}}
      )
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, "Done with default preset."} =
        ToolDispatch.execute(
          %{name: "spawn_agent", args: %{"task" => "do the sub-task"}},
          manifest
        )
    end

    test "returns error when task is missing" do
      manifest = ToolDispatch.build_manifest(@config)
      assert {:error, "spawn_agent requires task"} =
        ToolDispatch.execute(%{name: "spawn_agent", args: %{}}, manifest)
    end

    test "depth counter is restored after sub-agent failure" do
      Process.put(:spawn_agent_depth, 0)
      on_exit(fn -> Process.delete(:spawn_agent_depth) end)
      manifest = ToolDispatch.build_manifest(@config)
      _ = ToolDispatch.execute(%{name: "spawn_agent", args: %{"task" => "x", "preset" => "no_such_preset"}}, manifest)
      assert Process.get(:spawn_agent_depth) == 0
    end
  end

  describe "execute/3 — fence" do
    setup do
      dir = System.tmp_dir!() |> Path.join("shem_fence_test_#{:rand.uniform(99999)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, fence: dir}
    end

    test "read_file inside fence succeeds", %{fence: fence} do
      path = Path.join(fence, "test.txt")
      File.write!(path, "hello")
      call = %{name: "read_file", args: %{"path" => path}, id: "1"}
      manifest = ToolDispatch.build_manifest(%Config{task: "t", system_prompt: "s"})
      assert {:ok, "hello"} = ToolDispatch.execute(call, manifest, fence: fence, backend: Shem.Lab.Executor.Backend.Local)
    end

    test "read_file outside fence returns error tuple", %{fence: fence} do
      call = %{name: "read_file", args: %{"path" => "/etc/hostname"}, id: "1"}
      manifest = ToolDispatch.build_manifest(%Config{task: "t", system_prompt: "s"})
      assert {:error, reason} = ToolDispatch.execute(call, manifest, fence: fence, backend: Shem.Lab.Executor.Backend.Local)
      assert reason =~ "scope fence"
    end

    test "list_dir outside fence returns error tuple", %{fence: fence} do
      call = %{name: "list_dir", args: %{"path" => "/etc"}, id: "1"}
      manifest = ToolDispatch.build_manifest(%Config{task: "t", system_prompt: "s"})
      assert {:error, reason} = ToolDispatch.execute(call, manifest, fence: fence, backend: Shem.Lab.Executor.Backend.Local)
      assert reason =~ "scope fence"
    end

    test "execute/2 with no opts still works — fence defaults to nil" do
      call = %{name: "list_tools", args: %{}, id: "1"}
      manifest = ToolDispatch.build_manifest(%Config{task: "t", system_prompt: "s"})
      assert {:ok, _} = ToolDispatch.execute(call, manifest)
    end
  end

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
               ToolDispatch.execute(%{name: tool.name, args: %{}}, manifest)
    end

    test "low-trust tool is allowed when gate disabled", %{tool: tool} do
      manifest = [%{name: tool.name, description: "", source: {:lab, tool.id}, trust: :low}]
      assert {:ok, _} = ToolDispatch.execute(%{name: tool.name, args: %{}}, manifest)
    end

    test "unrated tool is allowed when gate enabled", %{tool: tool} do
      Application.put_env(:shem, :trust_gate_enabled, true)
      on_exit(fn -> Application.put_env(:shem, :trust_gate_enabled, false) end)

      manifest = [%{name: tool.name, description: "", source: {:lab, tool.id}, trust: :unrated}]
      assert {:ok, _} = ToolDispatch.execute(%{name: tool.name, args: %{}}, manifest)
    end

    test "medium-trust tool is allowed when gate enabled", %{tool: tool} do
      Application.put_env(:shem, :trust_gate_enabled, true)
      on_exit(fn -> Application.put_env(:shem, :trust_gate_enabled, false) end)

      manifest = [%{name: tool.name, description: "", source: {:lab, tool.id}, trust: :medium}]
      assert {:ok, _} = ToolDispatch.execute(%{name: tool.name, args: %{}}, manifest)
    end

    test "high-trust tool is allowed when gate enabled", %{tool: tool} do
      Application.put_env(:shem, :trust_gate_enabled, true)
      on_exit(fn -> Application.put_env(:shem, :trust_gate_enabled, false) end)

      manifest = [%{name: tool.name, description: "", source: {:lab, tool.id}, trust: :high}]
      assert {:ok, _} = ToolDispatch.execute(%{name: tool.name, args: %{}}, manifest)
    end

    test "builtin is never blocked regardless of gate", %{tool: _tool} do
      Application.put_env(:shem, :trust_gate_enabled, true)
      on_exit(fn -> Application.put_env(:shem, :trust_gate_enabled, false) end)

      path = Path.join(System.tmp_dir!(), "shem_gate_#{System.unique_integer([:positive])}.txt")
      File.write!(path, "x")
      on_exit(fn -> File.rm(path) end)

      manifest = [%{name: "read_file", description: "read", source: :builtin, trust: :builtin}]
      assert {:ok, "x"} =
               ToolDispatch.execute(%{name: "read_file", args: %{"path" => path}}, manifest)
    end
  end
end
