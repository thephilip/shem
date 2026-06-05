defmodule Shem.LLM.BudgetServerTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.BudgetServer

  defp start_server(limit, threshold \\ 0.8) do
    name = :"test_budget_#{:erlang.unique_integer([:positive])}"
    start_supervised!({BudgetServer, name: name, limit: limit, soft_threshold: threshold})
    name
  end

  describe "check/1" do
    test "returns :ok when tokens_used < limit" do
      srv = start_server(1000)
      assert :ok = BudgetServer.check(srv)
    end

    test "returns {:error, :budget_exhausted} when tokens_used == limit" do
      srv = start_server(10)
      BudgetServer.deduct(srv, 10)
      assert {:error, :budget_exhausted} = BudgetServer.check(srv)
    end

    test "returns {:error, :budget_exhausted} when tokens_used > limit" do
      srv = start_server(10)
      BudgetServer.deduct(srv, 15)
      assert {:error, :budget_exhausted} = BudgetServer.check(srv)
    end
  end

  describe "deduct/2" do
    test "increases tokens_used by the given amount" do
      srv = start_server(1000)
      BudgetServer.deduct(srv, 42)
      assert %{tokens_used: 42} = BudgetServer.status(srv)
    end

    test "is cumulative across multiple calls" do
      srv = start_server(1000)
      BudgetServer.deduct(srv, 10)
      BudgetServer.deduct(srv, 30)
      assert %{tokens_used: 40} = BudgetServer.status(srv)
    end
  end

  describe "soft warning" do
    test "soft_warned? is false initially" do
      srv = start_server(100)
      assert %{soft_warned?: false} = BudgetServer.status(srv)
    end

    test "soft_warned? becomes true after crossing threshold" do
      srv = start_server(100, 0.5)
      BudgetServer.deduct(srv, 51)
      assert %{soft_warned?: true} = BudgetServer.status(srv)
    end

    test "soft_warned? does not flip back after further deductions" do
      srv = start_server(100, 0.5)
      BudgetServer.deduct(srv, 51)
      BudgetServer.deduct(srv, 10)
      assert %{soft_warned?: true} = BudgetServer.status(srv)
    end
  end

  describe "reset/1" do
    test "resets tokens_used to zero" do
      srv = start_server(1000)
      BudgetServer.deduct(srv, 500)
      BudgetServer.reset(srv)
      assert %{tokens_used: 0} = BudgetServer.status(srv)
    end

    test "resets soft_warned? to false" do
      srv = start_server(100, 0.5)
      BudgetServer.deduct(srv, 60)
      BudgetServer.reset(srv)
      assert %{soft_warned?: false} = BudgetServer.status(srv)
    end
  end

  describe "status/1" do
    test "returns a map with all expected keys" do
      srv = start_server(500, 0.75)
      status = BudgetServer.status(srv)
      assert %{
               global_limit: 500,
               soft_threshold: 0.75,
               tokens_used: 0,
               soft_warned?: false
             } = status
    end
  end

  describe "config validation" do
    test "raises on invalid limit" do
      assert {:error, _} = start_supervised({BudgetServer, name: :bad_limit, limit: 0, soft_threshold: 0.8})
    end

    test "raises on soft_threshold > 1.0" do
      assert {:error, _} = start_supervised({BudgetServer, name: :bad_threshold, limit: 100, soft_threshold: 1.5})
    end
  end

  describe "budget_node_tokens config" do
    test "reads budget_node_tokens when set, ignoring llm_budget_limit" do
      Application.put_env(:shem, :budget_node_tokens, 999)
      on_exit(fn -> Application.delete_env(:shem, :budget_node_tokens) end)
      start_supervised!({BudgetServer, name: :test_node_budget})
      status = BudgetServer.status(:test_node_budget)
      assert status.global_limit == 999
    end

    test "explicit limit: opt wins when budget_node_tokens is absent" do
      Application.delete_env(:shem, :budget_node_tokens)
      start_supervised!({BudgetServer, name: :test_fallback_budget, limit: 12_345})
      status = BudgetServer.status(:test_fallback_budget)
      assert status.global_limit == 12_345
    end
  end
end
