defmodule Shem.LLM.Middleware.EventLoggerTest do
  use ExUnit.Case, async: false

  alias Shem.LLM.{Request, Response}
  alias Shem.LLM.Middleware.EventLogger

  defp request(session_id) do
    %Request{prompt: "hello", model: :default, session_id: session_id}
  end

  defp ok_response(tokens) do
    %Response{content: "ok", tokens_used: tokens, model: :default, latency_ms: 5}
  end

  describe "call/3 — with valid session_id" do
    test "appends :llm_call_started before and :llm_call_completed after on success" do
      {:ok, sid} = Shem.EventLog.start_session()
      next = fn _req -> {:ok, ok_response(20)} end

      assert {:ok, _} = EventLogger.call(request(sid), [], next)

      {:ok, events} = Shem.EventLog.events(sid)
      types = Enum.map(events, & &1.type)
      assert :llm_call_started in types
      assert :llm_call_completed in types
    end

    test ":llm_call_completed event carries tokens_used and latency_ms" do
      {:ok, sid} = Shem.EventLog.start_session()
      next = fn _req -> {:ok, ok_response(99)} end

      EventLogger.call(request(sid), [], next)

      {:ok, events} = Shem.EventLog.events(sid)
      completed = Enum.find(events, &(&1.type == :llm_call_completed))
      assert completed.payload.tokens_used == 99
      assert is_integer(completed.payload.latency_ms)
    end

    test "appends :llm_call_failed on error" do
      {:ok, sid} = Shem.EventLog.start_session()
      next = fn _req -> {:error, :transport_down} end

      assert {:error, :transport_down} = EventLogger.call(request(sid), [], next)

      {:ok, events} = Shem.EventLog.events(sid)
      failed = Enum.find(events, &(&1.type == :llm_call_failed))
      assert failed.payload.reason == ":transport_down"
    end

    test ":llm_call_started event carries prompt" do
      {:ok, sid} = Shem.EventLog.start_session()
      next = fn _req -> {:ok, ok_response(5)} end

      EventLogger.call(%Request{prompt: "tell me about BEAM", model: :default, session_id: sid}, [], next)

      {:ok, events} = Shem.EventLog.events(sid)
      started = Enum.find(events, &(&1.type == :llm_call_started))
      assert started.payload.prompt == "tell me about BEAM"
    end

    test ":llm_call_completed event carries content" do
      {:ok, sid} = Shem.EventLog.start_session()
      next = fn _req ->
        {:ok, %Response{content: "BEAM is great", tokens_used: 10, model: :default, latency_ms: 1}}
      end

      EventLogger.call(%Request{prompt: "hi", model: :default, session_id: sid}, [], next)

      {:ok, events} = Shem.EventLog.events(sid)
      completed = Enum.find(events, &(&1.type == :llm_call_completed))
      assert completed.payload.content == "BEAM is great"
    end
  end

  describe "call/3 — nil session_id" do
    test "passes through without touching the event log" do
      next = fn _req -> {:ok, ok_response(5)} end
      assert {:ok, _} = EventLogger.call(request(nil), [], next)
    end
  end
end
