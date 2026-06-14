defmodule Shem.ClusterTest do
  use ExUnit.Case, async: false

  describe "members/0 and nodes/0" do
    test "returns a list containing at least the current node" do
      assert Node.self() in Shem.Cluster.members()
    end

    test "nodes/0 is an alias for members/0" do
      assert Shem.Cluster.nodes() == Shem.Cluster.members()
    end
  end

  describe "agent_count/1" do
    test "returns a non-negative integer for the current node" do
      count = Shem.Cluster.agent_count(Node.self())
      assert is_integer(count) && count >= 0
    end

    test "returns 0 for an unknown node" do
      assert Shem.Cluster.agent_count(:unknown@nonexistent) == 0
    end
  end

  describe "Mnesia onboarding" do
    test "nodeup handler does not crash when onboard_mnesia is called for a non-existent node" do
      {:ok, pid} = Shem.Cluster.start_link([])
      send(pid, {:nodeup, :"fake@127.0.0.1"})
      Process.sleep(100)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "GenServer lifecycle" do
    test "starts and stops cleanly" do
      {:ok, pid} = Shem.Cluster.start_link([])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "nodeup/nodedown messages are handled without crash" do
      {:ok, pid} = Shem.Cluster.start_link([])
      send(pid, {:nodeup, :"fake@127.0.0.1"})
      send(pid, {:nodedown, :"fake@127.0.0.1"})
      Process.sleep(50)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "nodedown emits cluster_node_left to EventLog without crash" do
      {:ok, pid} = Shem.Cluster.start_link([])
      # EventLog may not be open for sys:cluster — the catch in emit/2 ensures no crash
      send(pid, {:nodedown, :"fake@127.0.0.1"})
      Process.sleep(50)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "NodeRegistry integration" do
    test "nodeup causes NodeRegistry.sync_node to be called without crash" do
      {:ok, pid} = Shem.Cluster.start_link([])
      send(pid, {:nodeup, :"fake@127.0.0.1"})
      Process.sleep(100)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "nodedown causes node to be removed from NodeRegistry" do
      fake = :"fake_nr@127.0.0.1"
      Shem.NodeRegistry.put_node(fake, %{"role" => "worker"})
      {:ok, pid} = Shem.Cluster.start_link([])
      send(pid, {:nodedown, fake})
      Process.sleep(100)
      assert Shem.NodeRegistry.labels(fake) == %{}
      GenServer.stop(pid)
    end
  end
end

defmodule Shem.ClusterDistributedTest do
  use ExUnit.Case, async: false

  @moduletag :distributed

  # These tests require a named node and EPMD. Run with:
  #   elixir --sname shem_test -S mix test --only distributed

  setup_all do
    unless Node.alive?() do
      Node.start(:shem_test, :shortnames)
    end

    :ok
  end

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
    :rpc.call(node, :application, :ensure_all_started, [:horde])

    {:ok, peer, node}
  end

  # Start a Horde.Registry on the peer node without linking it to the rpc caller.
  # Uses Code.eval_string so no local closure is serialized across nodes.
  defp start_peer_registry(peer_node) do
    :rpc.call(peer_node, Code, :eval_string, [
      "spawn(fn -> {:ok, _} = Horde.Registry.start_link(name: Shem.Registry, keys: :unique, members: :auto); Process.sleep(:infinity) end)"
    ])

    deadline = System.monotonic_time(:millisecond) + 3000

    Stream.repeatedly(fn ->
      case :rpc.call(peer_node, Process, :whereis, [Shem.Registry]) do
        pid when is_pid(pid) ->
          :ok

        _ ->
          if System.monotonic_time(:millisecond) < deadline do
            Process.sleep(100)
            :retry
          else
            :timeout
          end
      end
    end)
    |> Enum.find(&(&1 in [:ok, :timeout]))
    |> case do
      :ok -> :ok
      :timeout -> flunk("Peer registry did not start within 3s")
    end
  end

  defp assert_eventually(fun, timeout_ms, interval_ms \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if fun.() do
        :ok
      else
        now = System.monotonic_time(:millisecond)
        if now < deadline do
          Process.sleep(interval_ms)
          :retry
        else
          :timeout
        end
      end
    end)
    |> Enum.find(fn r -> r in [:ok, :timeout] end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("Condition not met within #{timeout_ms}ms")
    end
  end

  test "two nodes connect — Horde Registry membership syncs within 2s" do
    {:ok, peer, peer_node} = start_peer(:shem_b_reg)
    on_exit(fn -> :peer.stop(peer) end)

    start_peer_registry(peer_node)

    # Trigger explicit sync (simulates what Shem.Cluster does on :nodeup)
    all_nodes = [Node.self(), peer_node]
    Horde.Cluster.set_members(Shem.Registry, Enum.map(all_nodes, &{Shem.Registry, &1}))

    assert_eventually(
      fn ->
        members = Horde.Cluster.members(Shem.Registry)
        Enum.any?(members, fn {_, n} -> n == peer_node end)
      end,
      2000
    )
  end

  test "agent started on node A is visible in Horde.Registry from node B" do
    {:ok, peer, peer_node} = start_peer(:shem_b_agent)
    on_exit(fn -> :peer.stop(peer) end)

    start_peer_registry(peer_node)

    # Sync Horde members across both nodes
    all_nodes = [Node.self(), peer_node]
    Horde.Cluster.set_members(Shem.Registry, Enum.map(all_nodes, &{Shem.Registry, &1}))

    # Let Horde complete its initial member sync before registering
    Process.sleep(300)

    # Register a process locally under a test name
    test_name = "cluster_test_agent_#{System.unique_integer([:positive])}"
    {:ok, _} = Horde.Registry.register(Shem.Registry, test_name, :test_value)

    # Should be visible from peer_node via Horde's distributed registry
    assert_eventually(
      fn ->
        result = :rpc.call(peer_node, Horde.Registry, :lookup, [Shem.Registry, test_name])
        is_list(result) && length(result) == 1
      end,
      5000
    )
  end

  test "node leaving causes Shem.Cluster to emit nodedown without crash" do
    {:ok, peer, peer_node} = start_peer(:shem_b_leave)
    Node.connect(peer_node)

    {:ok, cluster_pid} = Shem.Cluster.start_link([])
    on_exit(fn -> if Process.alive?(cluster_pid), do: GenServer.stop(cluster_pid) end)

    :peer.stop(peer)

    # node monitor fires :nodedown — cluster must survive
    Process.sleep(200)
    assert Process.alive?(cluster_pid)
  end
end
