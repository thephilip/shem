# test/shem/agent/server_test.exs
defmodule Shem.Agent.ServerTest do
  use ExUnit.Case, async: false

  alias Shem.Agent

  setup do
    Shem.LLM.BudgetServer.reset()
    Shem.LLM.StubTransport.Server.reset()
    lab_dir = Application.get_env(:shem, :lab_dir)
    on_exit(fn -> File.rm_rf!(lab_dir) end)
    :ok
  end

  describe "Agent.Config" do
    test "struct has required fields with defaults" do
      config = %Agent.Config{task: "do something", system_prompt: "you are helpful"}
      assert config.task == "do something"
      assert config.system_prompt == "you are helpful"
      assert config.model == :default
      assert config.tools == []
      assert config.max_turns == 20
    end
  end
end
