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
end
