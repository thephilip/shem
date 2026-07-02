defmodule Shem.REST.ToolsTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Shem.REST.Router

  @opts Router.init([])

  setup do
    # Other suites flush the registry; rebuild seeds + graduated from disk.
    :ok = Shem.Lab.Registry.rescan()
  end

  test "GET /tools lists registry tools with id, description, schema" do
    conn = conn(:get, "/tools") |> Router.call(@opts)
    assert conn.status == 200
    %{"tools" => tools} = Jason.decode!(conn.resp_body)

    diff = Enum.find(tools, &(&1["id"] == "diff_text"))
    assert diff, "seed tool diff_text should be listed"
    assert diff["description"] =~ "diff"
    assert diff["schema"] == %{"a" => %{"type" => "string"}, "b" => %{"type" => "string"}}
  end
end
