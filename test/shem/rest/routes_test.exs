defmodule Shem.REST.RoutesTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Shem.REST.Router

  @opts Router.init([])

  test "GET /routes returns a JSON object with string keys and backend:model values" do
    conn = conn(:get, "/routes") |> Router.call(@opts)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    body = Jason.decode!(conn.resp_body)
    assert is_map(body)
    Enum.each(body, fn {_k, v} -> assert is_binary(v) end)
  end

  test "GET /unknown returns JSON 404" do
    conn = conn(:get, "/unknown") |> Router.call(@opts)
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "not found"}
  end
end
