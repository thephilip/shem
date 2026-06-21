defmodule Shem.Lab.GraduationGate.HardeningTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.GraduationGate.Hardening
  alias Shem.LLM.{StubTransport, Response}
  alias Shem.Tool

  # Calls Hardening.check/2 with the enabled flag passed explicitly, so the global
  # :progressive_hardening config is never mutated — that would race async tests
  # whose graduations would then fire stray stub-consuming LLM calls.

  setup do
    StubTransport.Server.reset()
    :ok
  end

  defp tool(name), do: %Tool{
    id: "harden_#{name}",
    name: name,
    runtime: {:beam, String.to_atom(name)},
    source: "def run(%{\"x\" => x}), do: x",
    test_source: "",
    graduated_at: DateTime.utc_now(),
    metadata: %{"description" => "echoes x", "schema" => %{}}
  }

  defp push(content),
    do: StubTransport.Server.push_response(
      {:ok, %Response{content: content, tokens_used: 10, model: :shadow, latency_ms: 0}}
    )

  test "returns the LLM score and logs a :hardening_check event when enabled" do
    push(Jason.encode!(%{"score" => 0.9, "reasoning" => "boundary inputs handled"}))

    assert {:ok, 0.9} = Hardening.check(tool("Harden1"), true)

    {:ok, sessions} = Shem.EventLog.list_sessions()

    assert Enum.any?(sessions, fn s ->
             case Shem.EventLog.events(s.id) do
               {:ok, events} -> Enum.any?(events, &(&1.type == :hardening_check))
               _ -> false
             end
           end)
  end

  test "extracts the verdict when the model wraps JSON in prose/markdown" do
    push("Here's my take:\n```json\n{\"score\": 0.7, \"reasoning\": \"fine\"}\n```\nThanks!")
    assert {:ok, 0.7} = Hardening.check(tool("Harden2"), true)
  end

  test "skips (no score) when the model returns no JSON" do
    push("This tool looks reasonable but I will not format as JSON.")
    assert :skip = Hardening.check(tool("Harden3"), true)
  end

  test "skips when the LLM call fails (empty stub queue)" do
    assert :skip = Hardening.check(tool("Harden4"), true)
  end

  test "skips without any LLM call when disabled" do
    assert :skip = Hardening.check(tool("Harden5"), false)
    assert StubTransport.Server.calls() == []
  end
end
