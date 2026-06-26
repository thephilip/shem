defmodule Shem.Lab.GraduationGateGoTest do
  use ExUnit.Case, async: false

  setup context do
    if context[:go_container] do
      runtime = System.find_executable("podman") || System.find_executable("docker")
      Process.put(:shem_executor_backend, Shem.Lab.Executor.Backend.Container)
      Application.put_env(:shem, :container_runtime_bin, runtime)

      prev_timeout = Application.get_env(:shem, :executor_timeout_ms)
      Application.put_env(:shem, :executor_timeout_ms, 120_000)
      on_exit(fn -> Application.put_env(:shem, :executor_timeout_ms, prev_timeout) end)
    end

    :ok
  end

  test "extract_name uses // name: comment, else a unique id-suffixed fallback" do
    assert Shem.Lab.GraduationGate.Go.extract_name(
             "// name: Upcase\npackage main\nfunc run(a map[string]any) any { return nil }",
             "abc123"
           ) == "Upcase"

    n1 = Shem.Lab.GraduationGate.Go.extract_name("package main\nfunc run(a map[string]any) any { return 1 }", "id0001")
    n2 = Shem.Lab.GraduationGate.Go.extract_name("package main\nfunc run(a map[string]any) any { return 2 }", "id0002")
    refute n1 == n2
  end

  @tag :go_container
  test "graduates a Go tool that passes go test" do
    source = """
    package main
    import "strings"
    // name: Upcase
    func run(a map[string]any) any {
      s, _ := a["s"].(string)
      return map[string]any{"up": strings.ToUpper(s)}
    }
    """
    test_source = """
    package main
    import "testing"
    func TestRun(t *testing.T) {
      got := run(map[string]any{"s": "hi"}).(map[string]any)
      if got["up"] != "HI" { t.Fatalf("want HI, got %v", got["up"]) }
    }
    """
    assert {:ok, tool} =
      Shem.Lab.GraduationGate.run(source, test_source, language: "go",
        description: "Upcases s. Args: s (string). Returns up (string).")
    assert tool.metadata["language"] == "go"
    assert tool.name == "Upcase"
  end

  @tag :go_container
  test "rejects a Go tool whose test fails" do
    source = "package main\nfunc run(_ map[string]any) any { return map[string]any{\"up\": \"wrong\"} }"
    test_source = """
    package main
    import "testing"
    func TestRun(t *testing.T) {
      if run(map[string]any{}).(map[string]any)["up"] != "HI" { t.Fatal("boom") }
    }
    """
    assert {:error, :gate, _} = Shem.Lab.GraduationGate.run(source, test_source, language: "go")
  end
end
