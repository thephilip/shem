defmodule Mix.Tasks.Demo do
  use Mix.Task

  @shortdoc "Run the Shem launch demo (~90s)"
  @moduledoc """
  Runs the Shem launch demo: four phases proving distributed agents,
  node failure recovery, time-travel debugging, and adversarial hardening.

      elixir --sname shem_demo -S mix demo
  """

  alias Shem.LLM.StubTransport.Server, as: StubServer
  alias Shem.Agent.Config
  alias Shem.{Agent, EventLog, Lab, LLM}

  @impl Mix.Task
  def run(_args) do
    guard_distribution!()
    configure_app()
    Mix.Task.run("app.start", [])
    local_stub = ensure_local_stub()

    banner("SHEM LAUNCH DEMO")
    IO.puts("")

    state = %{local_stub: local_stub}
    state = phase_1(state)
    state = phase_2(state)
    state = phase_3(state)
    phase_4(state)

    IO.puts(
      IO.ANSI.bright() <>
        IO.ANSI.green() <>
        """

        ═══════════════════════════════════════════════════════════════
          SHEM LAUNCH DEMO COMPLETE
          Distributed mesh ✓  Node recovery ✓  Time-travel ✓  Self-healing ✓
        ═══════════════════════════════════════════════════════════════
        """ <>
        IO.ANSI.reset()
    )
  end

  # ── ANSI helpers ────────────────────────────────────────────────────────────

  defp banner(text) do
    line = String.duplicate("═", 63)
    IO.puts(IO.ANSI.bright() <> IO.ANSI.cyan() <> "\n#{line}\n  #{text}\n#{line}" <> IO.ANSI.reset())
  end

  defp phase_banner(text) do
    IO.puts("\n" <> IO.ANSI.bright() <> IO.ANSI.yellow() <> "▶ #{text}" <> IO.ANSI.reset())
  end

  defp step(text), do: IO.puts("  " <> text)

  defp ok(text),
    do: IO.puts("  " <> IO.ANSI.green() <> "✓" <> IO.ANSI.reset() <> "  #{text}")

  defp info(text), do: IO.puts("    " <> IO.ANSI.light_black() <> text <> IO.ANSI.reset())

  defp fail!(phase, reason, hint) do
    IO.puts(IO.ANSI.red() <> "\n✗ PHASE #{phase} FAILED: #{inspect(reason)}" <> IO.ANSI.reset())
    IO.puts("  Hint: #{hint}")
    System.halt(1)
  end

  # ── Startup ─────────────────────────────────────────────────────────────────

  defp guard_distribution! do
    unless Node.alive?() do
      IO.puts(IO.ANSI.red() <> "✗ Erlang distribution is not active." <> IO.ANSI.reset())
      IO.puts("  Run with: elixir --sname shem_demo -S mix demo")
      System.halt(1)
    end
  end

  defp configure_app do
    Application.delete_env(:shem, :event_log_store)
    Application.put_env(:shem, :force_mnesia, true)

    Application.put_env(:shem, :llm_pipeline, [
      {Shem.LLM.Middleware.EventLogger, []},
      {Shem.LLM.StubTransport, [server: Shem.LLM.StubTransport.Server]}
    ])
  end

  defp ensure_local_stub do
    case Process.whereis(Shem.LLM.StubTransport.Server) do
      nil ->
        {:ok, pid} = StubServer.start_link(name: Shem.LLM.StubTransport.Server)
        pid

      pid ->
        StubServer.reset(pid)
        pid
    end
  end

  # ── Peer helper ─────────────────────────────────────────────────────────────

  defp start_peer(short_name) do
    build_path = Mix.Project.build_path()
    elixir_lib = :code.lib_dir(:elixir) |> Path.dirname() |> to_string()

    pa_args =
      (Path.wildcard(Path.join([elixir_lib, "*", "ebin"])) ++
         Path.wildcard(Path.join([build_path, "lib", "*", "ebin"])))
      |> Enum.flat_map(fn p -> [~c"-pa", String.to_charlist(p)] end)

    {:ok, peer, peer_node} = :peer.start(%{name: short_name, args: pa_args})

    :rpc.call(peer_node, :application, :ensure_all_started, [:elixir])
    :rpc.call(peer_node, :application, :ensure_all_started, [:mnesia])

    self_node = Node.self()

    :rpc.call(peer_node, Code, :eval_string, [
      """
      :mnesia.change_config(:extra_db_nodes, [:"#{self_node}"])
      case :mnesia.add_table_copy(:shem_events, node(), :disc_copies) do
        {:atomic, :ok} -> :ok
        {:aborted, {:already_exists, :shem_events, _}} -> :ok
      end
      :mnesia.wait_for_tables([:shem_events], 10_000)
      """
    ])

    :rpc.call(peer_node, Code, :eval_string, [
      """
      Application.delete_env(:shem, :event_log_store)
      Application.put_env(:shem, :llm_pipeline, [
        {Shem.LLM.Middleware.EventLogger, []},
        {Shem.LLM.StubTransport, [server: Shem.LLM.StubTransport.Server]}
      ])
      spawn(fn ->
        {:ok, _} = Horde.Registry.start_link(name: Shem.Registry, keys: :unique, members: :auto)
        {:ok, _} = Shem.AgentSupervisor.start_link([])
        {:ok, _} = Shem.NodeRegistry.start_link([])
        {:ok, _} = Shem.EventLog.start_link([])
        {:ok, _} = Shem.Lab.Registry.start_link([])
        {:ok, _} = :pg.start_link(:shem_streams)
        {:ok, _} = Shem.LLM.StubTransport.Server.start_link(name: Shem.LLM.StubTransport.Server)
        Process.sleep(:infinity)
      end)
      :ok
      """
    ])

    assert_eventually(
      fn ->
        case :rpc.call(peer_node, Process, :whereis, [Shem.LLM.StubTransport.Server]) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end,
      5_000
    )

    {peer, peer_node}
  end

  # ── assert_eventually ────────────────────────────────────────────────────────

  defp assert_eventually(fun, timeout_ms, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Enum.reduce_while(Stream.repeatedly(fn -> :tick end), nil, fn _, _ ->
      if fun.() do
        {:halt, :ok}
      else
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(interval_ms)
          {:cont, nil}
        else
          {:halt, :timeout}
        end
      end
    end) == :ok
  end

  # ── phase stubs (filled in Tasks 6–7) ───────────────────────────────────────

  defp phase_1(state), do: state
  defp phase_2(state), do: state
  defp phase_3(state), do: state
  defp phase_4(state), do: state
end
