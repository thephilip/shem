defmodule Shem.MCP.PackToolsTest do
  use ExUnit.Case, async: false
  alias Shem.MCP.Handlers.{InstallPack, UninstallPack}

  test "install_pack rejects missing repo arg" do
    # Schema.validate returns a 3-tuple {:error, :invalid_args, msg}
    assert {:error, :invalid_args, _} = InstallPack.call(%{})
  end

  test "uninstall_pack returns removed list for unknown pack" do
    assert {:ok, %{removed: []}} = UninstallPack.call(%{"name" => "nope"})
  end
end
