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
end
