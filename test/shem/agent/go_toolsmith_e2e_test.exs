defmodule Shem.Agent.GoToolsmithE2ETest do
  @moduledoc """
  End-to-end, keyless: a client-brain agent (driven turn-by-turn the way Claude
  Code would, no LLM key / no local model) authors a Go tool, graduates it
  through the real container gate, and the graduated tool runs via PortPool.

  Exercises the whole Go-runtime stack at once: go_toolsmith preset →
  write_tool (JSON-in-prose) → GraduationGate.Go (go test in container) →
  Registry → invoke_tool → PortPool (`go run`).

  Requires Go on PATH AND a container runtime (podman/docker), so it is tagged
  :go_container and excluded from the default suite.
  """
  use ExUnit.Case, async: false
  alias Shem.MCP.Handlers.{SpawnAgent, AgentStatus, ProvideTurn, InvokeTool}

  setup context do
    if context[:go_container] do
      # PortPool.Supervisor is disabled in test config; start it so the graduated
      # tool can be invoked through it.
      start_supervised!(Shem.Lab.PortPool.Supervisor)

      runtime = System.find_executable("podman") || System.find_executable("docker")
      Application.put_env(:shem, :container_runtime_bin, runtime)
      # Graduation runs inside the agent's process, which reads the backend from
      # Application env (not the test's process dict) — so set it there.
      prev_backend = Application.get_env(:shem, :resolved_executor_backend)
      Application.put_env(:shem, :resolved_executor_backend, Shem.Lab.Executor.Backend.Container)
      prev_timeout = Application.get_env(:shem, :executor_timeout_ms)
      # Go compile+test is slower than Deno — give it extra headroom.
      Application.put_env(:shem, :executor_timeout_ms, 120_000)

      lab_dir = Application.get_env(:shem, :lab_dir)
      on_exit(fn ->
        Application.put_env(:shem, :resolved_executor_backend, prev_backend)
        Application.put_env(:shem, :executor_timeout_ms, prev_timeout)
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

  @tag :go_container
  test "keyless client-brain agent authors, graduates, and runs a Go tool" do
    {:ok, %{"agent_id" => sid}} =
      SpawnAgent.call(%{
        "goal" => "a tool that reverses a string",
        "brain" => "client",
        "preset" => "go_toolsmith"
      })

    token = await_token(sid)

    # The "client" (stand-in for Claude Code) provides the turn: a write_tool call
    # carrying a self-contained Go tool + a Go test. Built with Jason.encode! so
    # the embedded source is correctly escaped — exactly what a real client sends.
    # Use a heredoc for go_src — NOT a ~S(...) sigil, because Go has parens that
    # collide with the sigil delimiter.
    go_src = """
    package main
    // name: ReverseString
    func run(a map[string]any) any {
      s, _ := a["s"].(string)
      r := []rune(s)
      for i, j := 0, len(r)-1; i < j; i, j = i+1, j-1 { r[i], r[j] = r[j], r[i] }
      return map[string]any{"rev": string(r)}
    }
    """

    go_test = """
    package main

    import "testing"

    func TestRun(t *testing.T) {
      got := run(map[string]any{"s": "abc"}).(map[string]any)
      if got["rev"] != "cba" {
        t.Fatalf("want cba, got %v", got["rev"])
      }
    }
    """

    call =
      Jason.encode!(%{
        "tool" => "write_tool",
        "args" => %{
          "language" => "go",
          "source" => go_src,
          "test_source" => go_test,
          "description" => "Reverses s. Args: s (string). Returns rev (string)."
        }
      })

    {:ok, _res} = ProvideTurn.call(%{"agent_id" => sid, "turn_token" => token, "content" => call})

    # Graduated: a go :port tool is now in the registry.
    tool =
      Enum.find(Shem.Lab.Registry.all(), fn t ->
        t.metadata["language"] == "go" and t.source =~ "[]rune"
      end)

    assert tool, "expected a graduated go tool in the registry"

    # And it actually runs, keyless, through the MCP invoke surface → PortPool → go run.
    assert {:ok, %{"rev" => "olleh"}} =
             InvokeTool.call(%{"id" => tool.id, "args" => %{"s" => "hello"}})
  end
end
