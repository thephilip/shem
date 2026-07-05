defmodule Shem.Lab.GraduationGate.HardeningActionsTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.GraduationGate.Hardening
  alias Shem.LLM.{StubTransport, Response}
  alias Shem.Tool

  setup do
    StubTransport.Server.reset()
    :ok
  end

  test "prompt includes declared actions with risks" do
    StubTransport.Server.push_response(
      {:ok, %Response{content: ~s({"score": 0.9, "reasoning": "ok"}), tokens_used: 10, model: :shadow, latency_ms: 0}}
    )

    tool = %Tool{
      id: "harden_actions",
      name: "Browserish",
      runtime: {:beam, :Browserish},
      source: "def run(%{\"action\" => a}), do: a",
      test_source: "",
      graduated_at: DateTime.utc_now(),
      metadata: %{
        "description" => "dispatches actions",
        "schema" => %{},
        "actions" => [
          %{"name" => "screenshot", "risk" => "read"},
          %{"name" => "evaluate", "risk" => "execute"}
        ]
      }
    }

    assert {:ok, 0.9} = Hardening.check(tool, true)

    captured_prompt = inspect(StubTransport.Server.calls(), limit: :infinity)
    assert captured_prompt =~ "evaluate"
    assert captured_prompt =~ "execute"
    assert captured_prompt =~ "Declared actions"
  end
end
