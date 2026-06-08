defmodule Shem.Memory.StoreTest do
  use ExUnit.Case, async: false

  alias Shem.Memory.Store

  setup do
    Store.flush()
    on_exit(fn -> Store.flush() end)
    :ok
  end

  describe "get/1" do
    test "returns {:error, :not_found} for unknown key" do
      assert {:error, :not_found} = Store.get("no_such_key")
    end
  end

  describe "put/2 and get/1" do
    test "stores a string value under a string key" do
      assert :ok = Store.put("user/name", "alice")
      assert {:ok, "alice"} = Store.get("user/name")
    end

    test "overwrites an existing key" do
      Store.put("k", "v1")
      Store.put("k", "v2")
      assert {:ok, "v2"} = Store.get("k")
    end

    test "written_at is stored (persistence test confirms schema)" do
      tmp_path = "tmp/memory_persist_#{System.unique_integer([:positive])}.dets"
      on_exit(fn -> File.rm(tmp_path) end)

      {:ok, pid1} = GenServer.start_link(Store, [path: tmp_path])
      GenServer.call(pid1, {:put, "persist_key", "persist_val"})
      GenServer.stop(pid1)

      {:ok, pid2} = GenServer.start_link(Store, [path: tmp_path])
      assert {:ok, "persist_val"} = GenServer.call(pid2, {:get, "persist_key"})
      # Confirm written_at is stored by checking raw DETS record has 3 elements
      [{_key, _val, written_at}] = :dets.lookup(
        to_charlist(tmp_path),
        "persist_key"
      )
      assert %DateTime{} = written_at
      GenServer.stop(pid2)
    end
  end

  describe "delete/1" do
    test "returns {:error, :not_found} for unknown key" do
      assert {:error, :not_found} = Store.delete("no_such_key")
    end

    test "removes an existing entry and returns :ok" do
      Store.put("to_delete", "bye")
      assert :ok = Store.delete("to_delete")
      assert {:error, :not_found} = Store.get("to_delete")
    end
  end

  describe "all/1" do
    test "returns empty list when store is empty" do
      assert [] = Store.all()
    end

    test "returns all entries as [{key, value}] sorted by key" do
      Store.put("b", "2")
      Store.put("a", "1")
      Store.put("c", "3")
      assert [{"a", "1"}, {"b", "2"}, {"c", "3"}] = Store.all()
    end

    test "filters by prefix when prefix is provided" do
      Store.put("coding/style", "functional")
      Store.put("coding/lang", "elixir")
      Store.put("user/name", "alice")
      result = Store.all("coding/")
      assert length(result) == 2
      assert Enum.all?(result, fn {k, _v} -> String.starts_with?(k, "coding/") end)
    end

    test "empty prefix string returns all entries" do
      Store.put("x", "1")
      Store.put("y", "2")
      assert length(Store.all("")) == 2
    end
  end

  describe "flush/0" do
    test "removes all entries" do
      Store.put("a", "1")
      Store.put("b", "2")
      Store.flush()
      assert [] = Store.all()
    end
  end
end
