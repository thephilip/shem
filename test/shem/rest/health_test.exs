defmodule Shem.REST.HealthTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Shem.REST.Router

  @opts Router.init([])

  test "GET /health returns 200 with required fields" do
    conn = conn(:get, "/health") |> Router.call(@opts)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["version"])
    assert is_integer(body["port"])
    assert is_boolean(body["tui"])
    assert is_integer(body["active_agents"])
    assert is_binary(body["host"])
  end

  test "GET /health active_agents is non-negative" do
    conn = conn(:get, "/health") |> Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    assert body["active_agents"] >= 0
  end
end
