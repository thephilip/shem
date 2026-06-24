defmodule Shem.Distributed.ClientBrainRoutingTest do
  use ExUnit.Case, async: false

  @moduletag :distributed

  # Run with:
  #   mix test test/shem/distributed/client_brain_routing_test.exs --sname plan_test --only distributed

  alias Shem.Agent

  setup_all do
    unless Node.alive?() do
      Node.start(:shem_test, :shortnames)
    end

    Application.delete_env(:shem, :event_log_store)
    Application.put_env(:shem, :force_mnesia, true)
    Supervisor.terminate_child(Shem.Supervisor, Shem.EventLog)
    Supervisor.restart_child(Shem.Supervisor, Shem.EventLog)

    Shem.LLM.StubTransport.Server.set_default(
      {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
    )

    on_exit(fn ->
      Application.delete_env(:shem, :force_mnesia)
      Application.put_env(:shem, :event_log_store, Shem.EventLog.FakeStore)
      Supervisor.terminate_child(Shem.Supervisor, Shem.EventLog)
      Supervisor.restart_child(Shem.Supervisor, Shem.EventLog)
    end)

    :ok
  end

  # ── Helpers (mirrors failover_test.exs pattern exactly) ─────────────────────

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

  defp setup_peer_full(peer_node) do
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

    :rpc.call(peer_node, Code, :eval_string, [
      """
      Application.delete_env(:shem, :event_log_store)
      spawn(fn ->
        {:ok, _} = Horde.Registry.start_link(name: Shem.Registry, keys: :unique, members: :auto)
        {:ok, _} = Shem.AgentSupervisor.start_link([])
        {:ok, _} = Shem.NodeRegistry.start_link([])
        {:ok, _} = Shem.EventLog.start_link([])
        {:ok, _} = Shem.Lab.Registry.start_link([])
        {:ok, _} = :pg.start_link(:shem_streams)
        Process.sleep(:infinity)
      end)
      :ok
      """
    ])

    assert_eventually(
      fn ->
        case :rpc.call(peer_node, Process, :whereis, [:shem_streams]) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end,
      5_000
    )

    all_nodes = [Node.self(), peer_node]
    Horde.Cluster.set_members(Shem.AgentSupervisor, Enum.map(all_nodes, &{Shem.AgentSupervisor, &1}))
    Horde.Cluster.set_members(Shem.Registry, Enum.map(all_nodes, &{Shem.Registry, &1}))

    assert_eventually(
      fn ->
        Horde.Cluster.members(Shem.AgentSupervisor)
        |> Enum.any?(fn {_, n} -> n == peer_node end)
      end,
      5_000
    )

    Process.sleep(500)
  end

  defp setup_stub_on_peer(peer_node) do
    :rpc.call(peer_node, Code, :eval_string, [
      """
      spawn(fn ->
        {:ok, _stub_pid} = Shem.LLM.StubTransport.Server.start_link(name: Shem.LLM.StubTransport.Server)
        Shem.LLM.StubTransport.Server.set_default(
          {:ok, %Shem.LLM.Response{content: "done", tokens_used: 1, model: :default, latency_ms: 1}}
        )
        {:ok, _budget_pid} = Shem.LLM.BudgetServer.start_link(name: Shem.LLM.BudgetServer)
        {:ok, _trust_pid} = Shem.Trust.Store.start_link()
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

    assert_eventually(
      fn ->
        case :rpc.call(peer_node, Process, :whereis, [Shem.LLM.StubTransport.Server]) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end,
      3_000
    )

    assert_eventually(
      fn ->
        case :rpc.call(peer_node, Process, :whereis, [Shem.Trust.Store]) do
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

  @tag :distributed
  test "provide_turn routes to the agent's node" do
    {:ok, peer, peer_node} = start_peer(:shem_clientbrain_a)
    on_exit(fn -> try do :peer.stop(peer) catch :exit, _ -> :ok end end)

    setup_peer_full(peer_node)
    setup_stub_on_peer(peer_node)

    # Spawn a client-brain agent placed on the peer node from local node A.
    {:ok, name, _sid} =
      Agent.start_with_preset("general", "double 4", brain: :client, placement: {:node, peer_node})

    # Wait until the agent is placed on the peer node AND parks in :awaiting_turn.
    assert_eventually(
      fn ->
        case GenServer.whereis(Shem.ProcessRegistry.via_tuple(name)) do
          nil ->
            false

          pid when node(pid) == peer_node ->
            try do
              case Agent.info(name) do
                {:ok, %{status: :awaiting_turn}} -> true
                _ -> false
              end
            catch
              :exit, _ -> false
            end

          _pid ->
            # Agent exists but not yet on peer — Horde may still be placing it.
            false
        end
      end,
      8_000
    )

    # From node A, call Agent.info to get the turn token (cross-node GenServer.call).
    {:ok, info} = Agent.info(name)
    assert info.status == :awaiting_turn
    token = info.turn_token
    assert is_tuple(token)

    # From node A, call provide_turn — this routes the GenServer.call to the pid
    # on node B (the peer). A successful return proves cross-node routing works.
    tool_json = ~s[{"tool":"execute_code","args":{"code":"IO.puts(8)"}}]
    {:ok, res} = Agent.provide_turn(name, token, tool_json)

    # The agent should have advanced: either re-parked (:awaiting_turn) or finished (:done).
    assert res.status in [:awaiting_turn, :done]

    # The agent process must still live on the peer node — it was never evacuated.
    pid = GenServer.whereis(Shem.ProcessRegistry.via_tuple(name))
    assert pid != nil
    assert node(pid) == peer_node
  end
end
