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
end
