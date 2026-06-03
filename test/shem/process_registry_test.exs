defmodule Shem.ProcessRegistryTest do
  use ExUnit.Case, async: true

  alias Shem.ProcessRegistry

  test "via_tuple/1 returns a correctly shaped Registry via-tuple" do
    assert {:via, Registry, {Shem.Registry, :my_agent}} =
             ProcessRegistry.via_tuple(:my_agent)
  end

  test "a process started with a via_tuple can be looked up in the Registry" do
    name = :"test_proc_#{System.unique_integer([:positive])}"
    via = ProcessRegistry.via_tuple(name)

    {:ok, pid} = Agent.start_link(fn -> 0 end, name: via)

    assert [{^pid, nil}] = Registry.lookup(Shem.Registry, name)
  end
end
