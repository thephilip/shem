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
    with :ok <- check_host(conn), {:ok, conn} <- check_token(conn) do
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
      nil -> {:ok, conn}
      token -> verify_token(conn, token)
    end
  end

  # API clients present `Authorization: Bearer <token>`. Browsers can't attach that
  # to a plain navigation, so we also accept the token from a `?token=` query param
  # (used once) or a `shem_token` cookie, and seed the cookie on the query-param hit
  # so subsequent navigations + same-origin /api fetches carry it automatically.
  # ponytail: raw token in an HttpOnly cookie; fine for a LAN dev UI, revisit if the
  # listener ever faces the public internet (then: short-lived signed session cookie).
  defp verify_token(conn, token) do
    conn = conn |> fetch_query_params() |> fetch_cookies()

    {presented, from_query?} =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> t | _] -> {t, false}
        _ -> {conn.params["token"] || conn.cookies["shem_token"], conn.params["token"] != nil}
      end

    cond do
      is_binary(presented) and Plug.Crypto.secure_compare(presented, token) ->
        conn =
          if from_query?,
            do: put_resp_cookie(conn, "shem_token", token, http_only: true, same_site: "Strict"),
            else: conn

        {:ok, conn}

      is_binary(presented) ->
        {:error, 401, "invalid token"}

      true ->
        {:error, 401, "missing bearer token"}
    end
  end
end
