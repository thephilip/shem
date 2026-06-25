defmodule Shem.Lab.GraduationGateJSTest do
  use ExUnit.Case, async: false

  setup context do
    if context[:deno_container] do
      runtime = System.find_executable("podman") || System.find_executable("docker")
      Process.put(:shem_executor_backend, Shem.Lab.Executor.Backend.Container)
      Application.put_env(:shem, :container_runtime_bin, runtime)

      prev_timeout = Application.get_env(:shem, :executor_timeout_ms)
      Application.put_env(:shem, :executor_timeout_ms, 60_000)
      on_exit(fn -> Application.put_env(:shem, :executor_timeout_ms, prev_timeout) end)
    end

    :ok
  end

  test "extract_name uses // name: comment, else a unique id-suffixed fallback" do
    # Readable name when the source declares one.
    assert Shem.Lab.GraduationGate.JS.extract_name(
             "// name: ReverseString\nexport function run(a){}",
             "abc123"
           ) == "ReverseString"

    # Guards the model-path collision: without a name comment, two distinct tools must
    # get DISTINCT names (dispatch resolves by name; duplicates would shadow each other).
    n1 = Shem.Lab.GraduationGate.JS.extract_name("export function run(a){ return 1 }", "id0001")
    n2 = Shem.Lab.GraduationGate.JS.extract_name("export function run(a){ return 2 }", "id0002")
    refute n1 == n2
  end

  @tag :deno_container
  test "graduates a Deno tool that passes deno test" do
    source = "export function run(a){ return { up: String(a.s).toUpperCase() } }"

    test_source = """
    import { run } from "./tool.ts";
    import { assertEquals } from "jsr:@std/assert";
    Deno.test("upcases", () => assertEquals(run({ s: "hi" }), { up: "HI" }));
    """

    assert {:ok, tool} =
             Shem.Lab.GraduationGate.run(source, test_source,
               language: "javascript",
               description: "Upcases s. Args: s (string). Returns up (string)."
             )

    assert tool.metadata["language"] == "javascript"
  end

  @tag :deno_container
  test "rejects a Deno tool whose test fails (trust boundary holds)" do
    source = "export function run(_a){ return { up: \"wrong\" } }"

    test_source = """
    import { run } from "./tool.ts";
    import { assertEquals } from "jsr:@std/assert";
    Deno.test("upcases", () => assertEquals(run({ s: "hi" }), { up: "HI" }));
    """

    assert {:error, :gate, _reason} =
             Shem.Lab.GraduationGate.run(source, test_source, language: "javascript")
  end
end
