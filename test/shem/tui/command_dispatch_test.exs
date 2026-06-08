defmodule Shem.TUI.CommandDispatchTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.CommandDispatch

  describe "parse/1 — free text" do
    test "plain text starts agent with general preset" do
      assert {:start_agent, "general", "fix the bug in foo.ex"} =
               CommandDispatch.parse("fix the bug in foo.ex")
    end

    test "empty string returns error" do
      assert {:error, _} = CommandDispatch.parse("")
    end

    test "plain text with leading/trailing spaces is trimmed" do
      assert {:start_agent, "general", "fix the bug"} =
             CommandDispatch.parse("  fix the bug  ")
    end

    test "whitespace-only input returns error" do
      assert {:error, _} = CommandDispatch.parse("   ")
    end
  end

  describe "parse/1 — /agent command" do
    test "/agent <preset> <task> starts agent with named preset" do
      assert {:start_agent, "coding", "fix the memory leak"} =
               CommandDispatch.parse("/agent coding fix the memory leak")
    end

    test "/agent with multi-word task" do
      assert {:start_agent, "explore", "find all GenServer modules in lib"} =
               CommandDispatch.parse("/agent explore find all GenServer modules in lib")
    end

    test "/agent with no task returns error" do
      assert {:error, _} = CommandDispatch.parse("/agent coding")
    end

    test "/agent with no preset and no task returns error" do
      assert {:error, _} = CommandDispatch.parse("/agent")
    end
  end

  describe "parse/1 — /stop command" do
    test "/stop returns stop_agent" do
      assert {:stop_agent} = CommandDispatch.parse("/stop")
    end
  end

  describe "parse/1 — /agents command" do
    test "/agents returns list_agents" do
      assert {:list_agents} = CommandDispatch.parse("/agents")
    end
  end

  describe "parse/1 — unknown slash commands" do
    test "unknown slash command returns error" do
      assert {:error, msg} = CommandDispatch.parse("/unknown")
      assert String.contains?(msg, "unknown command")
    end

    test "/run returns error (not supported — use /agent)" do
      assert {:error, _} = CommandDispatch.parse("/run do something")
    end
  end

  describe "/redteam command" do
    test "parses /redteam <name> into {:redteam, name}" do
      assert {:redteam, "my_tool"} = CommandDispatch.parse("/redteam my_tool")
    end

    test "trims whitespace from tool name" do
      assert {:redteam, "my_tool"} = CommandDispatch.parse("/redteam  my_tool  ")
    end

    test "returns error for /redteam with no tool name" do
      assert {:error, _} = CommandDispatch.parse("/redteam")
      assert {:error, _} = CommandDispatch.parse("/redteam   ")
    end
  end

  describe "parse/1 — /tools command" do
    test "/tools returns {:tools}" do
      assert {:tools} = CommandDispatch.parse("/tools")
    end

    test "/tools with trailing space returns {:tools}" do
      assert {:tools} = CommandDispatch.parse("/tools ")
    end
  end

  describe "parse/1 — /trust command" do
    test "/trust <name> returns {:trust, name}" do
      assert {:trust, "my_tool"} = CommandDispatch.parse("/trust my_tool")
    end

    test "/trust trims whitespace from tool name" do
      assert {:trust, "my_tool"} = CommandDispatch.parse("/trust  my_tool  ")
    end

    test "/trust with no name returns error" do
      assert {:error, msg} = CommandDispatch.parse("/trust")
      assert msg =~ "usage: /trust"
    end

    test "/trust with whitespace-only name returns error" do
      assert {:error, _} = CommandDispatch.parse("/trust   ")
    end
  end

  describe "parse/1 — /preset command" do
    test "/preset list returns {:preset_list}" do
      assert {:preset_list} = CommandDispatch.parse("/preset list")
    end

    test "/preset add <name> returns {:preset_add, name}" do
      assert {:preset_add, "my_preset"} = CommandDispatch.parse("/preset add my_preset")
    end

    test "/preset add trims whitespace from name" do
      assert {:preset_add, "my_preset"} = CommandDispatch.parse("/preset add  my_preset  ")
    end

    test "/preset delete <name> returns {:preset_delete, name}" do
      assert {:preset_delete, "my_preset"} = CommandDispatch.parse("/preset delete my_preset")
    end

    test "/preset delete trims whitespace from name" do
      assert {:preset_delete, "my_preset"} = CommandDispatch.parse("/preset delete  my_preset  ")
    end

    test "/preset with no subcommand returns error" do
      assert {:error, msg} = CommandDispatch.parse("/preset")
      assert msg =~ "usage: /preset"
    end

    test "/preset add with no name returns error" do
      assert {:error, msg} = CommandDispatch.parse("/preset add")
      assert msg =~ "usage: /preset add"
    end

    test "/preset delete with no name returns error" do
      assert {:error, msg} = CommandDispatch.parse("/preset delete")
      assert msg =~ "usage: /preset delete"
    end
  end

  describe "parse/1 — /llm commands" do
    test "/llm routes returns {:llm_routes}" do
      assert {:llm_routes} = CommandDispatch.parse("/llm routes")
    end

    test "/llm route single pair returns {:llm_route, list}" do
      assert {:llm_route, [{:reasoning, :llama_cpp, "phi4"}]} =
               CommandDispatch.parse("/llm route reasoning=phi4")
    end

    test "/llm route multiple pairs returns all routes" do
      assert {:llm_route, results} = CommandDispatch.parse("/llm route reasoning=phi4 tools=qwen3")
      assert {:reasoning, :llama_cpp, "phi4"} in results
      assert {:tools, :llama_cpp, "qwen3"} in results
    end

    test "/llm route with no pairs returns error" do
      assert {:error, msg} = CommandDispatch.parse("/llm route")
      assert msg =~ "usage: /llm route"
    end

    test "/llm route with invalid pair (no =) returns error" do
      assert {:error, msg} = CommandDispatch.parse("/llm route badformat")
      assert msg =~ "usage: /llm route"
    end

    test "/llm route with empty value returns error" do
      assert {:error, msg} = CommandDispatch.parse("/llm route reasoning=")
      assert msg =~ "usage: /llm route"
    end

    test "/llm route with empty key returns error" do
      assert {:error, msg} = CommandDispatch.parse("/llm route =phi4")
      assert msg =~ "usage: /llm route"
    end

    test "/llm with unknown subcommand returns error" do
      assert {:error, msg} = CommandDispatch.parse("/llm unknown")
      assert msg =~ "unknown"
    end

    test "/llm route with backend:model prefix" do
      assert {:llm_route, [{:default, :openai, "gpt-4o"}]} =
             CommandDispatch.parse("/llm route default=openai:gpt-4o")
    end

    test "/llm route with anthropic backend" do
      assert {:llm_route, [{:reasoning, :anthropic, "claude-sonnet-4-6"}]} =
             CommandDispatch.parse("/llm route reasoning=anthropic:claude-sonnet-4-6")
    end

    test "/llm route with unknown backend returns error" do
      assert {:error, msg} = CommandDispatch.parse("/llm route default=badbackend:model")
      assert msg =~ "unknown backend: badbackend"
      assert msg =~ "valid:"
    end

    test "/llm route mixed batch with and without backend prefix" do
      assert {:llm_route, pairs} =
             CommandDispatch.parse("/llm route default=openai:gpt-4o tools=phi4")
      assert {:default, :openai, "gpt-4o"} in pairs
      assert {:tools, :llama_cpp, "phi4"} in pairs
    end
  end

  describe "parse/1 — /hire command" do
    test "/hire <name> <role> returns {:hire, name, role}" do
      assert {:hire, "researcher", "summarises academic papers"} =
               CommandDispatch.parse("/hire researcher summarises academic papers")
    end

    test "/hire with single-word role works" do
      assert {:hire, "coder", "codes"} = CommandDispatch.parse("/hire coder codes")
    end

    test "/hire with no name returns error" do
      assert {:error, msg} = CommandDispatch.parse("/hire")
      assert msg =~ "usage: /hire"
    end

    test "/hire with name but no role returns error" do
      assert {:error, msg} = CommandDispatch.parse("/hire researcher")
      assert msg =~ "usage: /hire"
    end
  end
end
