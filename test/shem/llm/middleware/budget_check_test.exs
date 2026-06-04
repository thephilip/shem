defmodule Shem.LLM.Middleware.BudgetCheckTest do
  use ExUnit.Case, async: true

  alias Shem.LLM.{Request, Response, BudgetServer}
  alias Shem.LLM.Middleware.BudgetCheck

  defp start_server(limit, threshold \\ 0.8) do
    name = :"budget_check_test_#{:erlang.unique_integer([:positive])}"
    start_supervised!({BudgetServer, name: name, limit: limit, soft_threshold: threshold})
    name
  end

  defp request(session_id \\ nil) do
    %Request{prompt: "hello", model: :default, session_id: session_id}
  end

  defp ok_response(tokens) do
    %Response{content: "ok", tokens_used: tokens, model: :default, latency_ms: 1}
  end

  describe "call/3 — pre-transport" do
    test "passes through when budget is available" do
      srv = start_server(1000)
      next = fn _req -> {:ok, ok_response(10)} end

      assert {:ok, %Response{tokens_used: 10}} =
               BudgetCheck.call(request(), [budget_server: srv], next)
    end

    test "halts with :budget_exhausted when limit is reached" do
      srv = start_server(10)
      BudgetServer.deduct(srv, 10)
      next = fn _req -> flunk("next should not be called") end

      assert {:error, :budget_exhausted} =
               BudgetCheck.call(request(), [budget_server: srv], next)
    end
  end

  describe "call/3 — post-transport deduction" do
    test "deducts tokens from budget on success" do
      srv = start_server(1000)
      next = fn _req -> {:ok, ok_response(42)} end

      BudgetCheck.call(request(), [budget_server: srv], next)

      assert %{tokens_used: 42} = BudgetServer.status(srv)
    end

    test "does not deduct tokens on error" do
      srv = start_server(1000)
      next = fn _req -> {:error, :something_failed} end

      BudgetCheck.call(request(), [budget_server: srv], next)

      assert %{tokens_used: 0} = BudgetServer.status(srv)
    end
  end

  describe "soft warning" do
    test "soft_warned? flips after threshold is crossed" do
      srv = start_server(100, 0.5)
      next = fn _req -> {:ok, ok_response(60)} end

      BudgetCheck.call(request(), [budget_server: srv], next)

      assert %{soft_warned?: true} = BudgetServer.status(srv)
    end
  end
end
