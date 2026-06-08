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

  describe "stream/4" do
    setup do
      Shem.LLM.BudgetServer.reset()
      :ok
    end

    test "calls next.(req, chunk_fn) and returns result when budget ok" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      chunk_fn = fn t -> Agent.update(collector, &[t | &1]) end

      next = fn req, cf ->
        cf.("streamed")
        {:ok, %Shem.LLM.Response{content: "streamed", tokens_used: 3, model: req.model, latency_ms: 0}}
      end

      request = %Shem.LLM.Request{prompt: "p", model: :default}
      assert {:ok, %{content: "streamed"}} = BudgetCheck.stream(request, [], chunk_fn, next)
      assert Agent.get(collector, & &1) == ["streamed"]
    end

    test "returns {:error, :budget_exhausted} without calling next when budget is depleted" do
      Shem.LLM.BudgetServer.deduct(100_001)

      next = fn _req, _cf -> flunk("next should not be called") end
      chunk_fn = fn _t -> flunk("chunk_fn should not be called") end

      request = %Shem.LLM.Request{prompt: "p", model: :default}
      assert {:error, :budget_exhausted} = BudgetCheck.stream(request, [], chunk_fn, next)
    end

    test "deducts tokens from budget after successful stream" do
      status_before = Shem.LLM.BudgetServer.status()
      initial_used = status_before.tokens_used
      next = fn req, _cf ->
        {:ok, %Shem.LLM.Response{content: "x", tokens_used: 7, model: req.model, latency_ms: 0}}
      end

      request = %Shem.LLM.Request{prompt: "p", model: :default}
      assert {:ok, _} = BudgetCheck.stream(request, [], fn _t -> :ok end, next)
      assert Shem.LLM.BudgetServer.status().tokens_used == initial_used + 7
    end
  end
end
