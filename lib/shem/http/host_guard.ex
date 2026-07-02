defmodule Shem.HTTP.HostGuard do
  @moduledoc """
  First plug on the listener. Two checks:

  1. Host allowlist (always) — defeats DNS rebinding: a rebound page's
     request arrives with the attacker's Host header and is refused.
     Plug adapters parse the Host header into `conn.host` (port split off),
     so that is what we compare.
  2. Bearer token (only when `:auth_token` is configured; boot enforcement
     for non-loopback binds lives in `Shem.MCP.Server`).
  """
  import Plug.Conn

  @behaviour Plug

  @loopback ~w(localhost 127.0.0.1 ::1 [::1])

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with :ok <- check_host(conn), :ok <- check_token(conn) do
      conn
    else
      {:error, status, msg} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(%{error: msg}))
        |> halt()
    end
  end

  defp check_host(conn) do
    allowed =
      @loopback ++
        [Application.get_env(:shem, :mcp_host, "127.0.0.1")] ++
        Application.get_env(:shem, :allowed_hosts, [])

    if conn.host in allowed, do: :ok, else: {:error, 403, "host not allowed"}
  end

  defp check_token(conn) do
    case Application.get_env(:shem, :auth_token) do
      nil ->
        :ok

      token ->
        case get_req_header(conn, "authorization") do
          ["Bearer " <> presented | _] ->
            if Plug.Crypto.secure_compare(presented, token),
              do: :ok,
              else: {:error, 401, "invalid token"}

          _ ->
            {:error, 401, "missing bearer token"}
        end
    end
  end
end
