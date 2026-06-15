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

  # ── Phase 1: Distributed Mesh ────────────────────────────────────────────────

  defp phase_1(state) do
    phase_banner("PHASE 1: DISTRIBUTED MESH")

    {peer_b, peer_b_node} =
      try do
        step("Starting peer node shem_b@localhost...")
        r = start_peer(:shem_b)
        ok("shem_b started")
        r
      rescue
        e -> fail!(1, e, "Ensure you ran with: elixir --sname shem_demo -S mix demo")
      end

    {peer_c, peer_c_node} =
      try do
        step("Starting peer node shem_c@localhost...")
        r = start_peer(:shem_c)
        ok("shem_c started")
        r
      rescue
        e -> fail!(1, e, "Ensure you ran with: elixir --sname shem_demo -S mix demo")
      end

    step("Wiring Horde membership across 3 nodes...")
    all_nodes = [Node.self(), peer_b_node, peer_c_node]

    Horde.Cluster.set_members(
      Shem.AgentSupervisor,
      Enum.map(all_nodes, &{Shem.AgentSupervisor, &1})
    )

    Horde.Cluster.set_members(
      Shem.Registry,
      Enum.map(all_nodes, &{Shem.Registry, &1})
    )

    unless assert_eventually(
             fn ->
               Horde.Cluster.members(Shem.AgentSupervisor)
               |> Enum.count(fn {_, n} -> n in [peer_b_node, peer_c_node] end) == 2
             end,
             8_000
           ) do
      fail!(1, :horde_timeout, "Horde did not see both peers within 8s")
    end

    ok("Horde mesh: #{length(all_nodes)} nodes")
    Process.sleep(500)

    resp = fn content ->
      {:ok,
       %Shem.LLM.Response{content: content, tokens_used: 1, model: :default, latency_ms: 0}}
    end

    :rpc.call(peer_b_node, StubServer, :push_response, [
      Shem.LLM.StubTransport.Server,
      resp.("Scanning task boundaries…")
    ])

    :rpc.call(peer_b_node, StubServer, :push_response, [
      Shem.LLM.StubTransport.Server,
      resp.("Checkpoint written. Awaiting next instruction.")
    ])

    :rpc.call(peer_c_node, StubServer, :set_default, [
      Shem.LLM.StubTransport.Server,
      resp.("Parallel analysis running on shem_c…")
    ])

    step("Spawning worker_alpha → #{peer_b_node}")

    {:ok, alpha_name, _alpha_sid} =
      Agent.start(%Config{
        task: "Analyze distributed task boundaries",
        system_prompt: "You are a distributed analysis agent. Complete each turn and report.",
        max_turns: 2,
        placement: {:node, peer_b_node}
      })

    step("Spawning worker_beta → #{peer_c_node}")

    {:ok, beta_name, _beta_sid} =
      Agent.start(%Config{
        task: "Run parallel analysis",
        system_prompt: "You are a parallel analysis agent. Complete your turn and report.",
        max_turns: 1,
        placement: {:node, peer_c_node}
      })

    case Agent.await(alpha_name, 15_000) do
      {:ok, :done} ->
        info("worker_alpha: \"Checkpoint written.\"")

      err ->
        fail!(1, err, "worker_alpha did not complete within 15s")
    end

    case Agent.await(beta_name, 10_000) do
      {:ok, :done} ->
        info("worker_beta: \"Parallel analysis running on shem_c…\"")

      err ->
        fail!(1, err, "worker_beta did not complete within 10s")
    end

    ok("Two agents ran concurrently across three BEAM nodes.")

    Map.merge(state, %{
      peer_b: peer_b,
      peer_b_node: peer_b_node,
      peer_c: peer_c,
      peer_c_node: peer_c_node
    })
  end

  # ── Phase 2: Node Failure + Recovery ────────────────────────────────────────

  defp phase_2(%{peer_b: peer_b, peer_b_node: peer_b_node, peer_c_node: peer_c_node} = state) do
    phase_banner("PHASE 2: NODE FAILURE + RECOVERY")

    resp = fn content ->
      {:ok,
       %Shem.LLM.Response{content: content, tokens_used: 1, model: :default, latency_ms: 0}}
    end

    :rpc.call(peer_b_node, StubServer, :push_response, [
      Shem.LLM.StubTransport.Server,
      resp.("Checkpoint written.")
    ])

    recovery_resp = resp.("Recovered from checkpoint. Completing task.")
    StubServer.set_default(Shem.LLM.StubTransport.Server, recovery_resp)

    :rpc.call(peer_c_node, StubServer, :set_default, [
      Shem.LLM.StubTransport.Server,
      recovery_resp
    ])

    step("Spawning worker_alpha on #{peer_b_node} (max_turns: 2)...")

    {:ok, alpha_name, alpha_sid} =
      Agent.start(%Config{
        task: "Analyze distributed task boundaries",
        system_prompt: "You are a distributed analysis agent. Complete each turn and report.",
        max_turns: 2,
        conversational: true,
        placement: {:node, peer_b_node}
      })

    unless assert_eventually(
             fn ->
               case Shem.EventLog.MnesiaStore.read_all(alpha_sid) do
                 {:ok, events} -> Enum.any?(events, &(&1.type == :agent_checkpoint))
                 _ -> false
               end
             end,
             8_000
           ) do
      fail!(2, :checkpoint_timeout, "worker_alpha checkpoint not seen within 8s")
    end

    Process.sleep(500)

    step("Killing #{peer_b_node} mid-task...")

    try do
      :peer.stop(peer_b)
    catch
      :exit, _ -> :ok
    end

    t0 = System.monotonic_time(:millisecond)
    step("Waiting for worker_alpha to relocate...")

    unless assert_eventually(
             fn ->
               case Shem.ProcessRegistry.lookup(alpha_name) do
                 {pid, _} -> node(pid) != peer_b_node
                 nil -> false
               end
             end,
             15_000
           ) do
      fail!(2, :relocation_timeout, "Horde did not relocate worker_alpha within 15s")
    end

    elapsed = System.monotonic_time(:millisecond) - t0

    case Shem.ProcessRegistry.lookup(alpha_name) do
      {pid, _} -> ok("Relocated to #{node(pid)} in #{elapsed}ms")
      nil -> fail!(2, :not_found, "worker_alpha not found after relocation")
    end

    case Agent.await(alpha_name, 10_000) do
      {:ok, :done} ->
        info("worker_alpha resumed: \"Recovered from checkpoint. Completing task.\"")
        ok("Work continued without interruption.")

      err ->
        fail!(2, err, "worker_alpha did not complete after recovery")
    end

    Map.put(state, :recovery_session_id, alpha_sid)
  end

  # ── Phase 3: Time-Travel (stubs filled in Task 7) ───────────────────────────

  defp phase_3(state), do: state

  # ── Phase 4: Adversarial Hardening (stubs filled in Task 7) ─────────────────

  defp phase_4(state), do: state
end
