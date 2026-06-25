defmodule Shem.Agent.JsToolsmithE2ETest do
  @moduledoc """
  End-to-end, keyless: a client-brain agent (driven turn-by-turn the way Claude
  Code would, no LLM key / no local model) authors a Deno tool, graduates it
  through the real container gate, and the graduated tool runs via PortPool.

  Exercises the whole JS-runtime stack at once: js_toolsmith preset →
  write_tool (JSON-in-prose) → GraduationGate.JS (deno test in container) →
  Registry → invoke_tool → PortPool (`deno run`, deny-all).

  Requires deno on PATH AND a container runtime (podman/docker), so it is tagged
  :deno_container and excluded from the default suite.
  """
  use ExUnit.Case, async: false
  alias Shem.MCP.Handlers.{SpawnAgent, AgentStatus, ProvideTurn, InvokeTool}

  setup context do
    if context[:deno_container] do
      # PortPool.Supervisor is disabled in test config; start it so the graduated
      # tool can be invoked through it.
      start_supervised!(Shem.Lab.PortPool.Supervisor)

      runtime = System.find_executable("podman") || System.find_executable("docker")
      Application.put_env(:shem, :container_runtime_bin, runtime)
      # Graduation runs inside the agent's process, which reads the backend from
      # Application env (not the test's process dict) — so set it there.
      prev_backend = Application.get_env(:shem, :resolved_executor_backend)
      Application.put_env(:shem, :resolved_executor_backend, Shem.Lab.Executor.Backend.Container)
      prev = Application.get_env(:shem, :executor_timeout_ms)
      Application.put_env(:shem, :executor_timeout_ms, 60_000)

      lab_dir = Application.get_env(:shem, :lab_dir)
      on_exit(fn ->
        Application.put_env(:shem, :resolved_executor_backend, prev_backend)
        Application.put_env(:shem, :executor_timeout_ms, prev)
        File.rm_rf!(lab_dir)
        Shem.Lab.Registry.flush()
        Shem.Trust.Store.flush()
      end)
    end

    :ok
  end

  defp await_token(sid, n \\ 300)
  defp await_token(_sid, 0), do: flunk("agent never awaited a turn")
  defp await_token(sid, n) do
    {:ok, st} = AgentStatus.call(%{"agent_id" => sid})
    case st["status"] do
      "awaiting_turn" -> st["turn_token"]
      _ -> Process.sleep(20); await_token(sid, n - 1)
    end
  end

  @tag :deno_container
  test "keyless client-brain agent authors, graduates, and runs a Deno tool" do
    {:ok, %{"agent_id" => sid}} =
      SpawnAgent.call(%{
        "goal" => "a tool that reverses a string",
        "brain" => "client",
        "preset" => "js_toolsmith"
      })

    token = await_token(sid)

    # The "client" (stand-in for Claude Code) provides the turn: a write_tool call
    # carrying a self-contained Deno tool + a Deno test. Built with Jason.encode! so
    # the embedded source is correctly escaped — exactly what a real client sends.
    source = ~S|export function run(a){ return { rev: a.s.split("").reverse().join("") } }|

    test_source = """
    import { run } from "./tool.ts";
    import { assertEquals } from "jsr:@std/assert";
    Deno.test("reverses", () => assertEquals(run({ s: "abc" }), { rev: "cba" }));
    """

    call =
      Jason.encode!(%{
        "tool" => "write_tool",
        "args" => %{
          "language" => "javascript",
          "source" => source,
          "test_source" => test_source,
          "description" => "Reverses s. Args: s (string). Returns rev (string)."
        }
      })

    {:ok, _res} = ProvideTurn.call(%{"agent_id" => sid, "turn_token" => token, "content" => call})

    # Graduated: a javascript :port tool is now in the registry.
    tool =
      Enum.find(Shem.Lab.Registry.all(), fn t ->
        t.metadata["language"] == "javascript" and t.source =~ "reverse()"
      end)

    assert tool, "expected a graduated javascript tool in the registry"

    # And it actually runs, keyless, through the MCP invoke surface → PortPool → deno.
    assert {:ok, %{"rev" => "olleh"}} =
             InvokeTool.call(%{"id" => tool.id, "args" => %{"s" => "hello"}})
  end
end
