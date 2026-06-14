defmodule Shem.Distributed.FailoverTest do
  use ExUnit.Case, async: false

  @moduletag :distributed

  # Run with:
  #   elixir --sname shem_test -S mix test --only distributed

  alias Shem.EventLog.MnesiaStore
  alias Shem.Agent.Config

  setup_all do
    unless Node.alive?() do
      Node.start(:shem_test, :shortnames)
    end

    # Switch local EventLog to MnesiaStore.
    # test.exs hard-codes event_log_store: FakeStore which wins over the
    # Node.list() auto-detect. Delete it AND force Mnesia so that even if
    # no peers are connected yet, the restarted EventLog picks MnesiaStore.
    Application.delete_env(:shem, :event_log_store)
    Application.put_env(:shem, :force_mnesia, true)
    Supervisor.terminate_child(Shem.Supervisor, Shem.EventLog)
    Supervisor.restart_child(Shem.Supervisor, Shem.EventLog)

    # Set a default stub response on the local node so agents that migrate
    # here can run another turn without hitting :no_stub_response.
    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )

    on_exit(fn ->
      # Restore FakeStore so other (non-distributed) test suites are unaffected.
      Application.delete_env(:shem, :force_mnesia)
      Application.put_env(:shem, :event_log_store, Shem.EventLog.FakeStore)
      Supervisor.terminate_child(Shem.Supervisor, Shem.EventLog)
      Supervisor.restart_child(Shem.Supervisor, Shem.EventLog)
    end)

    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp start_peer(short_name) do
    build_path = Mix.Project.build_path()
    elixir_lib = :code.lib_dir(:elixir) |> Path.dirname() |> to_string()

    pa_args =
      (Path.wildcard(Path.join([elixir_lib, "*", "ebin"])) ++
         Path.wildcard(Path.join([build_path, "lib", "*", "ebin"])))
      |> Enum.flat_map(fn p -> [~c"-pa", String.to_charlist(p)] end)

    {:ok, peer, node} =
      :peer.start(%{
        name: short_name,
        args: pa_args
      })

    :rpc.call(node, :application, :ensure_all_started, [:elixir])
    :rpc.call(node, :application, :ensure_all_started, [:mnesia])
    {:ok, peer, node}
  end

  defp setup_mnesia_on_peer(peer_node) do
    self_node = Node.self()

    :rpc.call(peer_node, Code, :eval_string, [
      """
      Application.ensure_all_started(:mnesia)
      :mnesia.change_config(:extra_db_nodes, [:"#{self_node}"])
      case :mnesia.add_table_copy(:shem_events, node(), :disc_copies) do
        {:atomic, :ok} -> :ok
        {:aborted, {:already_exists, :shem_events, _}} -> :ok
      end
      :mnesia.wait_for_tables([:shem_events], 10_000)
      """
    ])
  end

  # Set up Horde, AgentSupervisor, NodeRegistry, EventLog, and LLM stub on
  # the peer, then wire up Horde cluster membership on both nodes.
  defp setup_peer_full(peer_node) do
    setup_mnesia_on_peer(peer_node)

    # Start Horde and supporting services on the peer using spawn so that
    # the RPC return value is a PID — not the Horde supervisor result.
    # Starting Horde directly in eval_string causes erpc replies ({Ref, :return, value})
    # to be delivered to the eval_string process which is linked to the
    # local `:peer` proxy, propagating as EXIT signals to the local Horde supervisor.
    # Using spawn breaks that link chain (same pattern as cluster_test.exs).
    :rpc.call(peer_node, Code, :eval_string, [
      """
      Application.delete_env(:shem, :event_log_store)
      spawn(fn ->
        {:ok, _} = Horde.Registry.start_link(name: Shem.Registry, keys: :unique, members: :auto)
        {:ok, _} = Shem.AgentSupervisor.start_link([])
        {:ok, _} = Shem.NodeRegistry.start_link([])
        {:ok, _} = Shem.EventLog.start_link([])
        {:ok, _} = Shem.Lab.Registry.start_link([])
        {:ok, _} = Registry.start_link(keys: :duplicate, name: Shem.StreamRegistry)
        Process.sleep(:infinity)
      end)
      :ok
      """
    ])

    # Poll until all key services are up on peer (StreamRegistry is last in the spawn).
    assert_eventually(
      fn ->
        case :rpc.call(peer_node, Process, :whereis, [Shem.StreamRegistry]) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end,
      5_000
    )

    # Explicitly wire Horde membership from the local node.
    # `members: :auto` handles placement routing (why labels/evac tests pass), but
    # death-detection monitors (needed for crash recovery) require explicit set_members
    # so Horde establishes Process.monitor on the peer's supervisor.
    # This is safe now because the peer's Horde is started inside spawn(), breaking
    # the link chain that previously caused {Ref, :return, ...} crashes.
    all_nodes = [Node.self(), peer_node]
    Horde.Cluster.set_members(Shem.AgentSupervisor, Enum.map(all_nodes, &{Shem.AgentSupervisor, &1}))
    Horde.Cluster.set_members(Shem.Registry, Enum.map(all_nodes, &{Shem.Registry, &1}))

    # Wait for Horde to see the peer as an alive member before proceeding.
    assert_eventually(
      fn ->
        Horde.Cluster.members(Shem.AgentSupervisor)
        |> Enum.any?(fn {_, n} -> n == peer_node end)
      end,
      5_000
    )

    # Extra wait for CRDT sync to fully propagate member status and monitors.
    Process.sleep(500)
  end

  defp setup_stub_on_peer(peer_node) do
    # Use spawn so the started servers survive the RPC call process exit.
    # start_link links the new process to the caller — if the :rpc evaluator
    # process exits after returning, it would kill any start_link'd servers.
    # Spawning a long-lived process that owns the servers avoids this.
    :rpc.call(peer_node, Code, :eval_string, [
      """
      spawn(fn ->
        {:ok, stub_pid} = Shem.LLM.StubTransport.Server.start_link(name: Shem.LLM.StubTransport.Server)
        Shem.LLM.StubTransport.Server.set_default(
          {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
        )
        {:ok, _budget_pid} = Shem.LLM.BudgetServer.start_link(name: Shem.LLM.BudgetServer)
        Process.sleep(:infinity)
      end)
      Application.put_env(:shem, :llm_pipeline, [
        {Shem.LLM.Middleware.BudgetCheck, [budget_server: Shem.LLM.BudgetServer]},
        {Shem.LLM.Middleware.EventLogger, []},
        {Shem.LLM.StubTransport, [server: Shem.LLM.StubTransport.Server]}
      ])
      Application.put_env(:shem, :llm_models, %{default: "llama3:latest"})
      :ok
      """
    ])

    # Poll until StubTransport.Server is registered on peer.
    assert_eventually(
      fn ->
        case :rpc.call(peer_node, Process, :whereis, [Shem.LLM.StubTransport.Server]) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end,
      3_000
    )
  end

  defp assert_eventually(fun, timeout_ms, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Enum.reduce_while(Stream.repeatedly(fn -> :tick end), nil, fn _, _ ->
      if fun.() do
        {:halt, :ok}
      else
        now = System.monotonic_time(:millisecond)

        if now < deadline do
          Process.sleep(interval_ms)
          {:cont, nil}
        else
          {:halt, :timeout}
        end
      end
    end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("Condition not met within #{timeout_ms}ms")
    end
  end

  # ── Tests ────────────────────────────────────────────────────────────────────

  test "crash recovery: agent reappears on local node after peer dies" do
    {:ok, peer, peer_node} = start_peer(:shem_fail_a)
    on_exit(fn -> try do :peer.stop(peer) catch :exit, _ -> :ok end end)

    setup_peer_full(peer_node)
    setup_stub_on_peer(peer_node)

    agent_name = "failover_crash_#{:erlang.unique_integer([:positive])}"
    config = %Config{
      task: "say done",
      system_prompt: "test",
      conversational: true,
      max_turns: 50,
      placement: {:node, peer_node}
    }

    {:ok, _pid, session_id} = Shem.AgentSupervisor.start_agent(agent_name, config)

    # Wait until at least one :agent_checkpoint event lands in Mnesia.
    assert_eventually(
      fn ->
        case MnesiaStore.read_all(session_id) do
          {:ok, events} -> Enum.any?(events, &(&1.type == :agent_checkpoint))
          _ -> false
        end
      end,
      8_000
    )

    # Extra wait to let CRDT sync the process entry from peer to local before
    # killing the peer. The DeltaCrdt's Merkle sync interval is 300ms but
    # multi-round tree comparison adds latency. 2 seconds is a safe margin.
    Process.sleep(2_000)

    # Kill the peer — Horde should redistribute the :transient agent to local.
    :peer.stop(peer)

    # Wait for agent to reappear on local node.
    assert_eventually(
      fn ->
        case GenServer.whereis(Shem.ProcessRegistry.via_tuple(agent_name)) do
          nil -> false
          pid -> node(pid) == Node.self()
        end
      end,
      10_000
    )

    # Wait for :agent_resumed event in Mnesia with prior_node set to the peer.
    assert_eventually(
      fn ->
        case MnesiaStore.read_all(session_id) do
          {:ok, events} ->
            Enum.any?(events, fn e ->
              e.type == :agent_resumed &&
                Map.get(e.payload, :prior_node) == peer_node
            end)

          _ ->
            false
        end
      end,
      10_000
    )
  end

  test "graceful evacuation: evacuate_all/0 migrates agent to local node" do
    {:ok, peer, peer_node} = start_peer(:shem_fail_b)
    on_exit(fn -> try do :peer.stop(peer) catch :exit, _ -> :ok end end)

    setup_peer_full(peer_node)
    setup_stub_on_peer(peer_node)

    agent_name = "failover_evac_#{:erlang.unique_integer([:positive])}"
    config = %Config{
      task: "say done",
      system_prompt: "test",
      conversational: true,
      max_turns: 50,
      placement: {:node, peer_node}
    }

    {:ok, _pid, session_id} = Shem.AgentSupervisor.start_agent(agent_name, config)

    # Wait for agent to reach :waiting state (first turn complete).
    assert_eventually(
      fn ->
        case GenServer.whereis(Shem.ProcessRegistry.via_tuple(agent_name)) do
          nil ->
            false

          pid ->
            try do
              {:ok, :waiting} == GenServer.call(pid, :status)
            catch
              :exit, _ -> false
            end
        end
      end,
      8_000
    )

    # Trigger graceful evacuation on the peer.
    :rpc.call(peer_node, Code, :eval_string, ["Shem.AgentSupervisor.evacuate_all()"])

    # Agent should appear on local node.
    assert_eventually(
      fn ->
        case GenServer.whereis(Shem.ProcessRegistry.via_tuple(agent_name)) do
          nil -> false
          pid -> node(pid) == Node.self()
        end
      end,
      10_000
    )

    # At least one :agent_checkpoint event must be in EventLog.
    {:ok, events} = MnesiaStore.read_all(session_id)
    assert Enum.any?(events, &(&1.type == :agent_checkpoint))
  end

  test "label placement: agent lands on node with matching labels" do
    {:ok, peer, peer_node} = start_peer(:shem_fail_c)
    on_exit(fn -> try do :peer.stop(peer) catch :exit, _ -> :ok end end)

    setup_peer_full(peer_node)
    setup_stub_on_peer(peer_node)

    # Set a distinctive label on the peer so local NodeRegistry can find it.
    label_value = "llama3-failover-#{:erlang.unique_integer([:positive])}"

    :rpc.call(peer_node, Code, :eval_string, [
      """
      Shem.NodeRegistry.set_labels(%{"model" => "#{label_value}"})
      """
    ])

    # Wait for local NodeRegistry to learn about the peer's label.
    assert_eventually(
      fn ->
        Shem.NodeRegistry.nodes_matching(%{"model" => label_value}) != []
      end,
      5_000
    )

    config = %Config{
      task: "say done",
      system_prompt: "test",
      placement: {:labels, %{"model" => label_value}}
    }

    {:ok, _pid, _session_id} = Shem.AgentSupervisor.start_agent("label_agent_#{:erlang.unique_integer([:positive])}", config)

    # Resolve which node matched.
    [target_node] = Shem.NodeRegistry.nodes_matching(%{"model" => label_value})

    # Wait for Horde to place the agent on the labeled node.
    assert_eventually(
      fn ->
        Horde.DynamicSupervisor.which_children(Shem.AgentSupervisor)
        |> Enum.any?(fn {_, pid, _, _} ->
          is_pid(pid) && node(pid) == target_node
        end)
      end,
      5_000
    )

    # Fetch the pid now that we know it's there.
    pid =
      Horde.DynamicSupervisor.which_children(Shem.AgentSupervisor)
      |> Enum.find_value(fn {_, p, _, _} ->
        if is_pid(p) && node(p) == target_node, do: p
      end)

    assert pid != nil, "Expected an agent pid on the labeled node #{target_node}"
    assert node(pid) == target_node
    assert target_node == peer_node
  end
end
