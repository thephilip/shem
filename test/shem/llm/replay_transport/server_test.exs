defmodule Shem.LLM.ReplayTransport.ServerTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.ReplayTransport.Server

  defp start_server do
    name = :"replay_srv_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Server, name: name})
    name
  end

  defp success_entry(prompt, content, tokens) do
    %{prompt: prompt, content: content, tokens_used: tokens}
  end

  defp failure_entry(prompt, reason) do
    %{prompt: prompt, error: reason}
  end

  describe "load/2 and pop/1" do
    test "pops entries in queue order" do
      srv = start_server()
      queue = [success_entry("p1", "c1", 10), success_entry("p2", "c2", 20)]
      Server.load(srv, queue)

      assert {:ok, %{prompt: "p1", content: "c1"}, 0} = Server.pop(srv)
      assert {:ok, %{prompt: "p2", content: "c2"}, 1} = Server.pop(srv)
    end

    test "returns {:exhausted, call_index} when queue is empty" do
      srv = start_server()
      Server.load(srv, [success_entry("p1", "c1", 5)])

      Server.pop(srv)
      assert {:exhausted, 1} = Server.pop(srv)
    end

    test "call_index increments per pop" do
      srv = start_server()
      Server.load(srv, [
        success_entry("p1", "c1", 1),
        success_entry("p2", "c2", 2),
        success_entry("p3", "c3", 3)
      ])

      assert {:ok, _, 0} = Server.pop(srv)
      assert {:ok, _, 1} = Server.pop(srv)
      assert {:ok, _, 2} = Server.pop(srv)
      assert {:exhausted, 3} = Server.pop(srv)
    end

    test "failure entries are returned as-is" do
      srv = start_server()
      Server.load(srv, [failure_entry("p1", ":transport_down")])

      assert {:ok, %{error: ":transport_down"}, 0} = Server.pop(srv)
    end

    test "load/2 resets call_index to 0" do
      srv = start_server()
      Server.load(srv, [success_entry("p1", "c1", 1)])
      Server.pop(srv)

      Server.load(srv, [success_entry("p2", "c2", 2)])
      assert {:ok, %{prompt: "p2"}, 0} = Server.pop(srv)
    end
  end

  describe "pop/1 before load" do
    test "returns {:exhausted, 0} when never loaded" do
      srv = start_server()
      assert {:exhausted, 0} = Server.pop(srv)
    end
  end
end
