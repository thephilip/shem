defmodule Shem.REST.PacksTest do
  use ExUnit.Case, async: false
  use Plug.Test
  alias Shem.REST.Handlers.Packs

  @opts Packs.init([])

  test "POST without repo is 422" do
    conn = conn(:post, "/", Jason.encode!(%{})) |> put_req_header("content-type", "application/json")
    conn = Packs.call(conn, @opts)
    assert conn.status == 422
  end

  test "DELETE unknown pack is 200 with empty removed" do
    conn = conn(:delete, "/nope") |> Packs.call(@opts)
    assert conn.status == 200
    assert %{"removed" => []} = Jason.decode!(conn.resp_body)
  end

  test "GET / returns 200 with packs list" do
    conn = conn(:get, "/") |> Packs.call(@opts)
    assert conn.status == 200
    assert %{"packs" => packs} = Jason.decode!(conn.resp_body)
    assert is_list(packs)
  end
end
