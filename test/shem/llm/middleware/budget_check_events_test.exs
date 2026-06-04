defmodule Shem.LLM.Middleware.BudgetCheckEventsTest do
  use ExUnit.Case, async: false

  alias Shem.LLM.{Request, Response, BudgetServer}
  alias Shem.LLM.Middleware.BudgetCheck
  alias Shem.EventLog

  defp start_server(limit, threshold \\ 0.8) do
    name = :"budget_check_events_test_#{:erlang.unique_integer([:positive])}"
    start_supervised!({BudgetServer, name: name, limit: limit, soft_threshold: threshold})
    name
  end

  defp request(session_id) do
    %Request{prompt: "hello", model: :default, session_id: session_id}
  end

  defp ok_response(tokens) do
    %Response{content: "ok", tokens_used: tokens, model: :default, latency_ms: 1}
  end

  defp start_session! do
    {:ok, session_id} = EventLog.start_session()
    session_id
  end

  defp events_of_type(session_id, type) do
    {:ok, events} = EventLog.events(session_id)
    Enum.filter(events, &(&1.type == type))
  end

  describe "budget_exhausted event" do
    test "appends :budget_exhausted event when session_id is set and budget is exhausted" do
      srv = start_server(10)
      BudgetServer.deduct(srv, 10)
      session_id = start_session!()

      assert {:error, :budget_exhausted} =
               BudgetCheck.call(request(session_id), [budget_server: srv], fn _ ->
                 flunk("next should not be called")
               end)

      assert [_event] = events_of_type(session_id, :budget_exhausted)
    end

    test "does not append :budget_exhausted event when session_id is nil" do
      srv = start_server(10)
      BudgetServer.deduct(srv, 10)
      session_id = start_session!()

      assert {:error, :budget_exhausted} =
               BudgetCheck.call(request(nil), [budget_server: srv], fn _ ->
                 flunk("next should not be called")
               end)

      # No events appended to any session
      assert [] = events_of_type(session_id, :budget_exhausted)
    end
  end

  describe "budget_soft_warning event" do
    test "appends :budget_soft_warning event when soft threshold is first crossed" do
      srv = start_server(100, 0.5)
      session_id = start_session!()

      BudgetCheck.call(request(session_id), [budget_server: srv], fn _req ->
        {:ok, ok_response(60)}
      end)

      assert [_event] = events_of_type(session_id, :budget_soft_warning)
    end

    test "does not append :budget_soft_warning on subsequent calls that stay over threshold" do
      srv = start_server(100, 0.5)
      session_id = start_session!()

      next = fn _req -> {:ok, ok_response(10)} end

      # First call crosses threshold (60 total)
      BudgetCheck.call(request(session_id), [budget_server: srv], fn _req ->
        {:ok, ok_response(60)}
      end)

      # Second call stays over threshold
      BudgetCheck.call(request(session_id), [budget_server: srv], next)

      # Still only one warning
      assert [_event] = events_of_type(session_id, :budget_soft_warning)
    end

    test "does not append :budget_soft_warning when session_id is nil" do
      srv = start_server(100, 0.5)
      session_id = start_session!()

      BudgetCheck.call(request(nil), [budget_server: srv], fn _req ->
        {:ok, ok_response(60)}
      end)

      assert [] = events_of_type(session_id, :budget_soft_warning)
    end

    test "does not append :budget_soft_warning when threshold is not crossed" do
      srv = start_server(100, 0.8)
      session_id = start_session!()

      BudgetCheck.call(request(session_id), [budget_server: srv], fn _req ->
        {:ok, ok_response(10)}
      end)

      assert [] = events_of_type(session_id, :budget_soft_warning)
    end
  end
end
