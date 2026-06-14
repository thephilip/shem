defmodule Shem.NodeRegistryTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, pid} = Shem.NodeRegistry.start_link(name: nil)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{registry: pid}
  end

  test "labels/1 returns empty map for unknown node", %{registry: pid} do
    assert Shem.NodeRegistry.labels(pid, :"unknown@nowhere") == %{}
  end

  test "own node labels are populated from config on start" do
    Application.put_env(:shem, :node_labels, %{"env" => "test"})
    {:ok, pid} = Shem.NodeRegistry.start_link(name: nil)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert Shem.NodeRegistry.labels(pid, Node.self()) == %{"env" => "test"}
  after
    Application.delete_env(:shem, :node_labels)
  end

  test "set_labels/1 updates own node's labels", %{registry: pid} do
    Shem.NodeRegistry.set_labels(pid, %{"role" => "worker"})
    assert Shem.NodeRegistry.labels(pid, Node.self()) == %{"role" => "worker"}
  end

  test "nodes_matching/1 returns nodes whose labels are a superset of selector", %{registry: pid} do
    Shem.NodeRegistry.set_labels(pid, %{"model" => "llama3", "gpu" => "true"})
    assert Node.self() in Shem.NodeRegistry.nodes_matching(pid, %{"model" => "llama3"})
    assert Node.self() in Shem.NodeRegistry.nodes_matching(pid, %{"model" => "llama3", "gpu" => "true"})
    assert Shem.NodeRegistry.nodes_matching(pid, %{"model" => "gpt4"}) == []
  end

  test "nodes_matching/1 requires all selector keys to match", %{registry: pid} do
    Shem.NodeRegistry.set_labels(pid, %{"model" => "llama3"})
    assert Shem.NodeRegistry.nodes_matching(pid, %{"model" => "llama3", "gpu" => "true"}) == []
  end

  test "all/0 returns map of all known nodes", %{registry: pid} do
    Shem.NodeRegistry.set_labels(pid, %{"x" => "1"})
    all = Shem.NodeRegistry.all(pid)
    assert is_map(all)
    assert Map.has_key?(all, Node.self())
  end

  test "remove_node/1 deletes a node entry", %{registry: pid} do
    fake = :"fake@nowhere"
    Shem.NodeRegistry.put_node(pid, fake, %{"role" => "removed"})
    assert Shem.NodeRegistry.labels(pid, fake) == %{"role" => "removed"}
    Shem.NodeRegistry.remove_node(pid, fake)
    assert Shem.NodeRegistry.labels(pid, fake) == %{}
  end

  test "put_node/2 stores labels for an arbitrary node", %{registry: pid} do
    Shem.NodeRegistry.put_node(pid, :"peer@host", %{"model" => "llama3"})
    assert Shem.NodeRegistry.labels(pid, :"peer@host") == %{"model" => "llama3"}
  end
end
