# test/shem/agent/tool_dispatch_test.exs
defmodule Shem.Agent.ToolDispatchTest do
  use ExUnit.Case, async: false

  alias Shem.Agent.{Config, ToolDispatch}
  alias Shem.Lab.Registry

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
      assert length(builtins) == 7
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
  end

  describe "execute/2 — list_tools built-in" do
    test "returns {:ok, formatted string} listing manifest tools" do
      manifest = [%{name: "foo", description: "does foo", source: :builtin}]
      assert {:ok, result} = ToolDispatch.execute(%{tool: "list_tools", args: %{}}, manifest)
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
      assert {:ok, "2"} = ToolDispatch.execute(%{tool: "run_code", args: %{"source" => source}}, manifest)
    end

    test "returns {:error, msg} for source with compile error" do
      manifest = [%{name: "run_code", description: "run", source: :builtin}]
      assert {:error, msg} =
               ToolDispatch.execute(
                 %{tool: "run_code", args: %{"source" => "this is not valid elixir !!!"}},
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
                 %{tool: "write_tool", args: %{"source" => source, "test_source" => test_src}},
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
                 %{tool: "write_tool", args: %{"source" => source, "test_source" => test_src}},
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
               ToolDispatch.execute(%{tool: tool.name, args: %{"x" => 1}}, manifest)
    end
  end

  describe "execute/2 — unknown tool" do
    test "returns {:error, 'unknown tool: name'} when not in manifest" do
      assert {:error, "unknown tool: ghost"} =
               ToolDispatch.execute(%{tool: "ghost", args: %{}}, [])
    end
  end

  describe "read_file built-in" do
    test "returns file contents on success" do
      path = Path.join(System.tmp_dir!(), "shem_test_read_#{System.unique_integer([:positive])}.txt")
      File.write!(path, "hello world")
      on_exit(fn -> File.rm(path) end)

      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, "hello world"} = ToolDispatch.execute(%{tool: "read_file", args: %{"path" => path}}, manifest)
    end

    test "returns error for missing file" do
      manifest = ToolDispatch.build_manifest(@config)
      result = ToolDispatch.execute(%{tool: "read_file", args: %{"path" => "/nonexistent/path/xyz"}}, manifest)
      assert match?({:error, _}, result)
    end
  end

  describe "write_file built-in" do
    test "writes file and returns byte count message" do
      path = Path.join(System.tmp_dir!(), "shem_test_write_#{System.unique_integer([:positive])}.txt")
      on_exit(fn -> File.rm(path) end)

      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, msg} = ToolDispatch.execute(%{tool: "write_file", args: %{"path" => path, "content" => "test content"}}, manifest)
      assert String.contains?(msg, "bytes")
      assert File.read!(path) == "test content"
    end

    test "returns error for unwritable path" do
      manifest = ToolDispatch.build_manifest(@config)
      result = ToolDispatch.execute(%{tool: "write_file", args: %{"path" => "/nonexistent_dir/file.txt", "content" => "x"}}, manifest)
      assert match?({:error, _}, result)
    end
  end

  describe "list_dir built-in" do
    test "returns newline-joined directory entries" do
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, entries} = ToolDispatch.execute(%{tool: "list_dir", args: %{"path" => "lib/shem"}}, manifest)
      assert String.contains?(entries, "agent")
      assert String.contains?(entries, "event_log.ex")
    end

    test "returns error for missing directory" do
      manifest = ToolDispatch.build_manifest(@config)
      result = ToolDispatch.execute(%{tool: "list_dir", args: %{"path" => "/nonexistent_xyz"}}, manifest)
      assert match?({:error, _}, result)
    end
  end

  describe "shell built-in" do
    test "returns stdout for successful command" do
      manifest = ToolDispatch.build_manifest(@config)
      assert {:ok, output} = ToolDispatch.execute(%{tool: "shell", args: %{"cmd" => "echo hello"}}, manifest)
      assert String.trim(output) == "hello"
    end

    test "returns exit code error for failing command" do
      manifest = ToolDispatch.build_manifest(@config)
      result = ToolDispatch.execute(%{tool: "shell", args: %{"cmd" => "exit 1"}}, manifest)
      assert match?({:error, "exit 1:" <> _}, result)
    end

    test "returns timeout error when exceeded" do
      manifest = ToolDispatch.build_manifest(@config)
      result = ToolDispatch.execute(%{tool: "shell", args: %{"cmd" => "sleep 10", "timeout_ms" => 100}}, manifest)
      assert match?({:error, "timeout after 100ms"}, result)
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
end
