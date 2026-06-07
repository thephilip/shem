# test/shem/agent/turn_test.exs
defmodule Shem.Agent.TurnTest do
  use ExUnit.Case, async: true

  alias Shem.Agent.Turn

  describe "parse_response/1" do
    test "returns {:done, content} when no JSON tool call present" do
      assert {:done, "The answer is 42."} = Turn.parse_response("The answer is 42.")
    end

    test "extracts a single tool call embedded in prose" do
      content = ~s(I'll write a tool.\n{"tool": "write_tool", "args": {"name": "Foo"}}\nDone.)
      assert {:tool_calls, [call], ^content} = Turn.parse_response(content)
      assert call == %{id: nil, name: "write_tool", args: %{"name" => "Foo"}}
    end

    test "extracts multiple tool calls" do
      content = ~s({"tool": "run_code", "args": {"source": "x"}}\n{"tool": "list_tools", "args": {}})
      assert {:tool_calls, [c1, c2], ^content} = Turn.parse_response(content)
      assert c1.name == "run_code"
      assert c2.name == "list_tools"
    end

    test "ignores non-tool JSON objects" do
      content = ~s(Here is some JSON: {"key": "value"}. No tool call.)
      assert {:done, ^content} = Turn.parse_response(content)
    end

    test "handles tool call with no args key — defaults to empty map" do
      content = ~s({"tool": "list_tools"})
      assert {:tool_calls, [%{id: nil, name: "list_tools", args: %{}}], ^content} =
               Turn.parse_response(content)
    end

    test "returns {:done, content} on empty string" do
      assert {:done, ""} = Turn.parse_response("")
    end

    test "handles nested args object" do
      content = ~s({"tool": "write_tool", "args": {"name": "T", "source": "defmodule T do\\nend"}})
      assert {:tool_calls, [call], _} = Turn.parse_response(content)
      assert call.args["source"] =~ "defmodule"
    end

    # When args is not a map, the first clause (requires is_map(args)) is skipped,
    # but the second clause matches {"tool" => tool} and defaults args to %{}.
    # The non-map args value is silently dropped.
    test "tool call where args is not a map — falls back to empty args" do
      content = ~s({"tool": "foo", "args": "not_a_map"})
      assert {:tool_calls, [%{id: nil, name: "foo", args: %{}}], ^content} = Turn.parse_response(content)
    end

    # The regex ~r/\{(?:[^{}]|\{[^{}]*\})*\}/ only handles 1 level of {} nesting.
    # For args with 2-level nesting (e.g. {"meta": {"k": "v"}}), the outer object
    # is not captured — only the innermost nested object is matched, which has no
    # "tool" key, so the result is {:done, content}. This test documents that limitation.
    test "returns :done for tool call with 2-level nested args — regex limitation" do
      content = ~s({"tool": "foo", "args": {"meta": {"k": "v"}}})
      assert {:done, ^content} = Turn.parse_response(content)
    end
  end

  describe "strip_thinking/1" do
    test "parse_response strips <think> block before extracting tool calls" do
      content = "<think>\nLet me think. {\"tool\": \"fake\", \"args\": {}}\n</think>\n{\"tool\": \"list_tools\", \"args\": {}}"
      assert {:tool_calls, [%{name: "list_tools"}], _} =
               Turn.parse_response(Turn.strip_thinking(content))
    end

    test "parse_response on content without <think> block is unchanged" do
      content = "{\"tool\": \"list_tools\", \"args\": {}}"
      assert {:tool_calls, [%{name: "list_tools"}], _} = Turn.parse_response(content)
    end

    test "strip_thinking removes multiline think block" do
      content = "<think>\nsome\nmultiline\nthinking\n</think>\nhello"
      assert Turn.strip_thinking(content) == "hello"
    end

    test "strips multiple <think> blocks" do
      content = "<think>first</think>middle<think>second</think>end"
      assert Turn.strip_thinking(content) == "middleend"
    end

    test "returns empty string when content is only a <think> block" do
      assert Turn.strip_thinking("<think>just thinking</think>") == ""
    end
  end

  describe "build_prompt/3" do
    @manifest [
      %{name: "list_tools", description: "List tools.", source: :builtin},
      %{name: "run_code", description: "Run code.", source: :builtin}
    ]

    test "includes system prompt" do
      prompt = Turn.build_prompt("Be helpful.", @manifest, [%{role: :user, content: "task"}])
      assert prompt =~ "Be helpful."
    end

    test "includes tool names and descriptions in manifest section" do
      prompt = Turn.build_prompt("sys", @manifest, [%{role: :user, content: "task"}])
      assert prompt =~ "list_tools"
      assert prompt =~ "List tools."
      assert prompt =~ "run_code"
    end

    test "renders user history entry" do
      prompt = Turn.build_prompt("sys", @manifest, [%{role: :user, content: "my task"}])
      assert prompt =~ "User: my task"
    end

    test "renders assistant history entry" do
      history = [
        %{role: :user, content: "task"},
        %{role: :assistant, content: "thinking..."}
      ]
      prompt = Turn.build_prompt("sys", @manifest, history)
      assert prompt =~ "Assistant: thinking..."
    end

    test "renders tool result verbatim" do
      history = [
        %{role: :user, content: "task"},
        %{role: :assistant, content: "calling"},
        %{role: :tool, content: "Tool result (run_code): 42"}
      ]
      prompt = Turn.build_prompt("sys", @manifest, history)
      assert prompt =~ "Tool result (run_code): 42"
    end

    test "ends with 'Assistant:' to cue next completion" do
      prompt = Turn.build_prompt("sys", @manifest, [%{role: :user, content: "task"}])
      assert String.ends_with?(String.trim_trailing(prompt), "Assistant:")
    end

    test "includes tool call JSON format instructions" do
      prompt = Turn.build_prompt("sys", @manifest, [%{role: :user, content: "t"}])
      assert prompt =~ ~s({"tool":)
    end
  end

  describe "build_request/4" do
    @req_manifest [
      %{name: "list_tools", description: "List tools.", source: :builtin},
      %{name: "run_code", description: "Run code.", source: :builtin}
    ]

    test "prompt field is populated via build_prompt" do
      request = Turn.build_request(:default, "Be helpful.", @req_manifest, [%{role: :user, content: "task"}])
      assert request.prompt =~ "Be helpful."
      assert request.prompt =~ "task"
    end

    test "system field matches the system_prompt argument" do
      request = Turn.build_request(:default, "You are precise.", @req_manifest, [%{role: :user, content: "task"}])
      assert request.system == "You are precise."
    end

    test "model field matches the model argument" do
      request = Turn.build_request(:openai, "sys", @req_manifest, [%{role: :user, content: "task"}])
      assert request.model == :openai
    end

    test "tools field populated from manifest when non-empty" do
      request = Turn.build_request(:default, "sys", @req_manifest, [%{role: :user, content: "task"}])
      assert is_list(request.tools)
      assert length(request.tools) == length(@req_manifest)
      assert hd(request.tools).name == "list_tools"
    end

    test "tools field is nil when manifest is empty" do
      request = Turn.build_request(:default, "sys", [], [%{role: :user, content: "task"}])
      assert is_nil(request.tools)
    end

    test "messages has no tool header — tool manifest no longer injected as user message" do
      request = Turn.build_request(:default, "sys", @req_manifest, [%{role: :user, content: "task"}])
      refute Enum.any?(request.messages, fn m ->
        is_binary(m.content) and String.contains?(m.content, "Available tools")
      end)
    end

    test "history :tool role is preserved in messages (no longer mapped to :user)" do
      history = [
        %{role: :user,      content: "task"},
        %{role: :assistant, content: "calling"},
        %{role: :tool,      content: "Tool result: 42"}
      ]
      request = Turn.build_request(:default, "sys", [], history)
      roles = Enum.map(request.messages, & &1.role)
      assert :tool in roles
    end

    test "assistant tool_calls preserved in messages" do
      history = [
        %{role: :user,      content: "task"},
        %{role: :assistant, content: nil,
          tool_calls: [%{id: "c1", name: "run_code", args: %{"source" => "1"}}]}
      ]
      request = Turn.build_request(:default, "sys", [], history)
      assistant = Enum.find(request.messages, &(&1.role == :assistant))
      assert assistant.tool_calls == [%{id: "c1", name: "run_code", args: %{"source" => "1"}}]
    end

    test "tool result with tool_call_id preserved in messages" do
      history = [
        %{role: :user, content: "task"},
        %{role: :tool, content: "42", tool_call_id: "c1"}
      ]
      request = Turn.build_request(:default, "sys", [], history)
      tool_msg = Enum.find(request.messages, &(&1.role == :tool))
      assert tool_msg.tool_call_id == "c1"
    end

    test "history :assistant role preserved in messages" do
      history = [
        %{role: :user, content: "hi"},
        %{role: :assistant, content: "hello"}
      ]
      request = Turn.build_request(:default, "sys", [], history)
      assert Enum.any?(request.messages, &(&1.role == :assistant and &1.content == "hello"))
    end

    test "messages is nil when both manifest and history are empty" do
      request = Turn.build_request(:default, "sys", [], [])
      assert request.messages == nil
    end
  end

  describe "step/4" do
    alias Shem.Agent.Config
    alias Shem.LLM.{Response, StubTransport}

    @config %Config{task: "do X", system_prompt: "be helpful"}
    @manifest [%{name: "list_tools", description: "list", source: :builtin}]

    setup do
      Shem.LLM.BudgetServer.reset()
      StubTransport.Server.reset()
      :ok
    end

    test "returns {:done, content} when LLM response has no tool call" do
      StubTransport.Server.push_response(
        {:ok, %Response{content: "The answer is 42.", tokens_used: 5, model: :default, latency_ms: 1}}
      )
      {:ok, sid} = Shem.EventLog.start_session()
      assert {:done, "The answer is 42."} =
               Turn.step(@config, sid, [%{role: :user, content: "do X"}], @manifest)
    end

    test "returns {:tool_calls, calls, raw} when LLM response contains tool call" do
      raw = ~s(I'll call a tool.\n{"tool": "list_tools", "args": {}})
      StubTransport.Server.push_response(
        {:ok, %Response{content: raw, tokens_used: 10, model: :default, latency_ms: 1}}
      )
      {:ok, sid} = Shem.EventLog.start_session()
      assert {:tool_calls, [%{name: "list_tools", args: %{}}], ^raw} =
               Turn.step(@config, sid, [%{role: :user, content: "do X"}], @manifest)
    end

    test "returns {:error, reason} when LLM transport fails" do
      StubTransport.Server.push_response({:error, :no_stub_response})
      {:ok, sid} = Shem.EventLog.start_session()
      assert {:error, _} =
               Turn.step(@config, sid, [%{role: :user, content: "do X"}], @manifest)
    end
  end

  describe "step/4 — native tool_calls path" do
    test "returns {:tool_calls, calls, content} when Response has tool_calls" do
      tool_call = %{id: "call_1", name: "run_code", args: %{"source" => "1 + 1"}}
      stub_response = %Shem.LLM.Response{
        content: nil,
        tool_calls: [tool_call],
        tokens_used: 5,
        model: :default,
        latency_ms: 10
      }

      config = %Shem.Agent.Config{
        task: "t",
        system_prompt: "sys",
        model: :default,
        max_turns: 5
      }

      Shem.LLM.StubTransport.Server.push_response({:ok, stub_response})
      Shem.LLM.BudgetServer.reset()

      {:ok, sid} = Shem.EventLog.start_session()
      result = Turn.step(config, sid, [], [])
      assert {:tool_calls, [^tool_call], ""} = result
    end
  end
end
