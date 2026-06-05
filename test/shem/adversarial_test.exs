defmodule Shem.AdversarialTest do
  use ExUnit.Case, async: false

  alias Shem.{Adversarial, Lab}
  alias Shem.LLM.{Response, StubTransport}

  setup do
    StubTransport.Server.reset()
    Shem.LLM.BudgetServer.reset()
    :ok
  end

  describe "start_hardening/1 when supervisor not running" do
    test "returns {:ok, :disabled} without crashing" do
      # In test env, start_adversarial: false so Supervisor isn't started
      assert {:ok, :disabled} = Adversarial.start_hardening("some_id")
    end
  end

  describe "status/1" do
    test "returns {:error, :not_found} for unknown job name" do
      assert {:error, :not_found} = Adversarial.status("no_such_job")
    end
  end
end
