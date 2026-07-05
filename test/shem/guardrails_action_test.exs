defmodule Shem.GuardrailsActionTest do
  use ExUnit.Case, async: false
  alias Shem.Guardrails

  setup do
    on_exit(fn -> Application.delete_env(:shem, :tool_policy) end)
  end

  test "no policy, no declared actions: ok" do
    assert :ok = Guardrails.check_action("t", %{}, policy: nil, actions: nil)
  end

  test "host deny whole tool" do
    Application.put_env(:shem, :tool_policy, %{deny: ["browser"]})
    assert {:blocked, _} = Guardrails.check_action("browser", %{"action" => "screenshot"},
             policy: nil, actions: ["screenshot"])
  end

  test "host deny tool.action blocks only that action" do
    Application.put_env(:shem, :tool_policy, %{deny: ["browser.evaluate"]})
    assert {:blocked, _} = Guardrails.check_action("browser", %{"action" => "evaluate"},
             policy: nil, actions: ["evaluate", "screenshot"])
    assert :ok = Guardrails.check_action("browser", %{"action" => "screenshot"},
             policy: nil, actions: ["evaluate", "screenshot"])
  end

  test "per-agent policy unions with host policy" do
    Application.put_env(:shem, :tool_policy, %{deny: ["a.x"]})
    assert {:blocked, _} = Guardrails.check_action("a", %{"action" => "y"},
             policy: %{deny: ["a.y"]}, actions: ["x", "y"])
  end

  test "undeclared action is blocked fail-closed" do
    assert {:blocked, _} = Guardrails.check_action("browser", %{"action" => "smuggled"},
             policy: nil, actions: ["screenshot"])
  end

  test "declared actions but missing action arg is blocked" do
    assert {:blocked, _} = Guardrails.check_action("browser", %{}, policy: nil, actions: ["screenshot"])
  end

  test "tool without declared actions is policed at whole-tool granularity only" do
    Application.put_env(:shem, :tool_policy, %{deny: ["other.thing"]})
    assert :ok = Guardrails.check_action("plain", %{"action" => "anything"}, policy: nil, actions: nil)
  end
end
