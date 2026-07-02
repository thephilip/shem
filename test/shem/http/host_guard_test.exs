defmodule Shem.HTTP.HostGuardTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Shem.HTTP.Router

  @opts Router.init([])

  # Plug adapters parse the Host header into conn.host (port split off) —
  # setting conn.host is exactly what a real request's Host header becomes.
  defp req(host, headers \\ []) do
    Enum.reduce(
      headers,
      %{conn(:get, "/api/presets") | host: host},
      fn {k, v}, c -> put_req_header(c, k, v) end
    )
    |> Router.call(@opts)
  end

  test "loopback hosts pass" do
    for host <- ["localhost", "127.0.0.1", "::1", "[::1]"] do
      assert req(host).status == 200, "expected #{host} to pass"
    end
  end

  test "foreign host is rejected 403 (DNS rebinding)" do
    conn = req("evil.example.com")
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "host not allowed"}
  end

  test "missing/empty host is rejected" do
    assert req("").status == 403
  end

  test "configured extra host passes" do
    prev = Application.get_env(:shem, :allowed_hosts, [])
    Application.put_env(:shem, :allowed_hosts, ["shem.lan"])
    on_exit(fn -> Application.put_env(:shem, :allowed_hosts, prev) end)
    assert req("shem.lan").status == 200
  end

  test "with auth_token set: correct bearer passes, wrong/absent 401" do
    Application.put_env(:shem, :auth_token, "sekrit")
    on_exit(fn -> Application.delete_env(:shem, :auth_token) end)

    assert req("localhost", [{"authorization", "Bearer sekrit"}]).status == 200
    assert req("localhost", [{"authorization", "Bearer wrong"}]).status == 401
    assert req("localhost").status == 401
  end
end
