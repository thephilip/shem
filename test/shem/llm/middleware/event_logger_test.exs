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

  describe "stream/4" do
    test "appends llm_call_started and llm_call_completed events around the stream" do
      {:ok, session_id} = Shem.EventLog.start_session("eltest_stream_#{System.unique_integer()}")

      next = fn req, cf ->
        cf.("token")
        {:ok, %Shem.LLM.Response{content: "token", tokens_used: 2, model: req.model, latency_ms: 0}}
      end

      request = %Shem.LLM.Request{prompt: "p", model: :default, session_id: session_id}
      assert {:ok, _} = EventLogger.stream(request, [], fn _t -> :ok end, next)

      {:ok, events} = Shem.EventLog.events(session_id)
      types = Enum.map(events, & &1.type)
      assert :llm_call_started in types
      assert :llm_call_completed in types
    end

    test "passes chunk_fn through to next unchanged" do
      {:ok, collector} = Agent.start_link(fn -> [] end)
      chunk_fn = fn t -> Agent.update(collector, &[t | &1]) end

      next = fn _req, cf ->
        cf.("live")
        {:ok, %Shem.LLM.Response{content: "live", tokens_used: 1, model: :default, latency_ms: 0}}
      end

      request = %Shem.LLM.Request{prompt: "p", model: :default, session_id: nil}
      assert {:ok, _} = EventLogger.stream(request, [], chunk_fn, next)
      assert Agent.get(collector, & &1) == ["live"]
    end
  end
end
