defmodule Shem.REST.PresetsTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Shem.REST.Router

  @opts Router.init([])

  test "GET /presets returns JSON list with name and description" do
    conn = conn(:get, "/presets") |> Router.call(@opts)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    body = Jason.decode!(conn.resp_body)
    assert is_list(body)
    assert length(body) >= 3
    first = hd(body)
    assert Map.has_key?(first, "name")
    assert Map.has_key?(first, "description")
  end

  test "GET /unknown returns JSON 404" do
    conn = conn(:get, "/unknown") |> Router.call(@opts)
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "not found"}
  end
end
