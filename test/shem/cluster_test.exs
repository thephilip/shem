defmodule Shem.ClusterTest do
  use ExUnit.Case, async: false

  describe "nodes/0" do
    test "returns a list containing at least the current node" do
      nodes = Shem.Cluster.nodes()
      assert is_list(nodes)
      assert Node.self() in nodes
    end

    test "works without the GenServer running (pure function)" do
      # nodes/0 calls Node.self() | Node.list() directly — no GenServer needed
      assert is_list(Shem.Cluster.nodes())
    end
  end

  describe "GenServer lifecycle" do
    test "starts and stops cleanly" do
      {:ok, pid} = Shem.Cluster.start_link([])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "handle_info nodeup/nodedown are handled without crash" do
      {:ok, pid} = Shem.Cluster.start_link([])
      send(pid, {:nodeup, :"fake@127.0.0.1"})
      send(pid, {:nodedown, :"fake@127.0.0.1"})
      Process.sleep(20)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
