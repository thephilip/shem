defmodule Shem.Agent.ClientBrainToolsmithTest do
  use ExUnit.Case, async: false
  alias Shem.MCP.Handlers.{SpawnAgent, AgentStatus, ProvideTurn}

  setup do
    lab_dir = Application.get_env(:shem, :lab_dir)
    on_exit(fn ->
      File.rm_rf!(lab_dir)
      Shem.Lab.Registry.flush()
      Shem.Trust.Store.flush()
    end)
    :ok
  end

  # copied from test/shem/mcp/provide_turn_test.exs
  defp await_token(sid, n \\ 300)
  defp await_token(_sid, 0), do: flunk("never awaited")
  defp await_token(sid, n) do
    {:ok, st} = AgentStatus.call(%{"agent_id" => sid})
    case st["status"] do
      "awaiting_turn" -> st["turn_token"]
      _ -> Process.sleep(20); await_token(sid, n - 1)
    end
  end

  test "client-brain agent calls write_tool (JSON-in-prose) and graduates an elixir tool" do
    {:ok, %{"agent_id" => sid}} =
      SpawnAgent.call(%{"goal" => "graduate a doubling tool",
                        "brain" => "client", "preset" => "elixir_toolsmith"})
    token = await_token(sid)

    # Claude's turn: a write_tool call as JSON-in-prose (the client-brain calling
    # convention). Built with Jason.encode! so the embedded source code is correctly
    # escaped — exactly what a real client (Claude Code) would send over the wire.
    source = "defmodule Dbl do\n  def run(%{\"n\" => n}), do: %{\"out\" => n * 2}\nend"
    # The elixir gate runs the test module's run/0 and treats a raise as failure
    # (see graduation_gate_test.exs), so test_source is a plain module, not ExUnit.
    test_source =
      "defmodule DblTest do\n  def run do\n    %{\"out\" => 6} = Dbl.run(%{\"n\" => 3})\n    :ok\n  end\nend"

    call =
      Jason.encode!(%{
        "tool" => "write_tool",
        "args" => %{
          "language" => "elixir",
          "source" => source,
          "test_source" => test_source,
          "description" => "Doubles n. Args: n (int). Returns out (int)."
        }
      })

    {:ok, _res} = ProvideTurn.call(%{"agent_id" => sid, "turn_token" => token, "content" => call})

    assert Enum.any?(Shem.Lab.Registry.all(), fn t -> t.source =~ "n * 2" end)
  end
end
