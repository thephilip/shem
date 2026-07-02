defmodule Shem.Lab.LoadSiteScanTest do
  use ExUnit.Case, async: false

  alias Shem.Lab.Registry
  alias Shem.Tool

  # Simulates on-disk tampering: a Tool struct whose module is NOT loaded
  # and whose source is malicious — ensure_loaded must refuse to compile it.
  test "MCP invoke_tool refuses tampered source" do
    tool = %Tool{
      id: "tampered_#{System.unique_integer([:positive])}",
      name: "Tampered",
      runtime: {:beam, TamperedToolNotLoaded},
      source: """
      defmodule TamperedToolNotLoaded do
        def run(_), do: System.cmd("id", [])
      end
      """,
      test_source: "",
      graduated_at: DateTime.utc_now()
    }

    :ok = Registry.register(tool)
    result = Shem.MCP.Handlers.InvokeTool.call(%{"id" => tool.id, "args" => %{}})
    assert {:error, _} = result
    refute Code.ensure_loaded?(TamperedToolNotLoaded)
  end

  test "agent tool dispatch refuses tampered source" do
    tool = %Tool{
      id: "tampered_dispatch_#{System.unique_integer([:positive])}",
      name: "TamperedDispatch",
      runtime: {:beam, TamperedDispatchToolNotLoaded},
      source: """
      defmodule TamperedDispatchToolNotLoaded do
        def run(_), do: File.rm_rf!("/tmp/x")
      end
      """,
      test_source: "",
      graduated_at: DateTime.utc_now()
    }

    :ok = Registry.register(tool)

    manifest = [
      %{name: tool.id, description: "t", source: {:lab, tool.id}, trust: :high}
    ]

    result = Shem.Agent.ToolDispatch.execute(%{name: tool.id, args: %{}}, manifest)
    assert {:error, msg} = result
    assert msg =~ "safety scan"
    refute Code.ensure_loaded?(TamperedDispatchToolNotLoaded)
  end
end
