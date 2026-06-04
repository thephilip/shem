defmodule Shem.LLM.ReplayTransportTest do
  use ExUnit.Case, async: false

  alias Shem.LLM.{Request, Response, ReplayTransport}
  alias Shem.LLM.ReplayTransport.Server

  defp start_server(queue \\ []) do
    name = :"rt_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Server, name: name})
    Server.load(name, queue)
    name
  end

  defp request(prompt, session_id \\ nil) do
    %Request{prompt: prompt, model: :default, session_id: session_id}
  end

  defp success_entry(prompt, content, tokens \\ 10) do
    %{prompt: prompt, content: content, tokens_used: tokens}
  end

  describe "prompt match" do
    test "returns {:ok, %Response{}} with recorded content" do
      srv = start_server([success_entry("hello", "world", 5)])

      assert {:ok, %Response{content: "world", tokens_used: 5, latency_ms: 0}} =
               ReplayTransport.call(request("hello"), [server: srv], fn _ -> :unreachable end)
    end

    test "response carries model atom from request" do
      srv = start_server([success_entry("hi", "there", 3)])

      assert {:ok, %Response{model: :default}} =
               ReplayTransport.call(request("hi"), [server: srv], fn _ -> :unreachable end)
    end

    test "does not append divergence event when prompts match" do
      {:ok, sid} = Shem.EventLog.start_session()
      srv = start_server([success_entry("exact", "reply", 1)])

      ReplayTransport.call(request("exact", sid), [server: srv], fn _ -> :unreachable end)

      {:ok, events} = Shem.EventLog.events(sid)
      assert Enum.all?(events, &(&1.type != :llm_call_diverged))
    end
  end

  describe "prompt divergence" do
    test "still returns recorded content (permissive)" do
      srv = start_server([success_entry("original", "recorded reply", 7)])

      assert {:ok, %Response{content: "recorded reply"}} =
               ReplayTransport.call(request("different"), [server: srv], fn _ -> :unreachable end)
    end

    test "appends :llm_call_diverged event when session_id is set" do
      {:ok, sid} = Shem.EventLog.start_session()
      srv = start_server([success_entry("original prompt", "reply", 5)])

      ReplayTransport.call(request("changed prompt", sid), [server: srv], fn _ -> :unreachable end)

      {:ok, events} = Shem.EventLog.events(sid)
      diverged = Enum.find(events, &(&1.type == :llm_call_diverged))
      assert diverged.payload.original_prompt == "original prompt"
      assert diverged.payload.replay_prompt == "changed prompt"
      assert diverged.payload.recorded_content == "reply"
      assert diverged.payload.call_index == 0
    end

    test "does not append divergence event when session_id is nil" do
      srv = start_server([success_entry("original", "reply", 1)])

      assert {:ok, _} =
               ReplayTransport.call(request("different", nil), [server: srv], fn _ -> :unreachable end)
    end
  end

  describe "queue exhaustion" do
    test "returns {:error, :replay_exhausted}" do
      srv = start_server([])

      assert {:error, :replay_exhausted} =
               ReplayTransport.call(request("any"), [server: srv], fn _ -> :unreachable end)
    end

    test "appends :replay_exhausted event when session_id is set" do
      {:ok, sid} = Shem.EventLog.start_session()
      srv = start_server([])

      ReplayTransport.call(request("unanswered", sid), [server: srv], fn _ -> :unreachable end)

      {:ok, events} = Shem.EventLog.events(sid)
      exhausted = Enum.find(events, &(&1.type == :replay_exhausted))
      assert exhausted.payload.call_index == 0
      assert exhausted.payload.replay_prompt == "unanswered"
    end
  end

  describe "replayed failures" do
    test "returns {:error, {:replayed_failure, reason_string}}" do
      srv = start_server([%{prompt: "p", error: ":transport_down"}])

      assert {:error, {:replayed_failure, ":transport_down"}} =
               ReplayTransport.call(request("p"), [server: srv], fn _ -> :unreachable end)
    end
  end
end
