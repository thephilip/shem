defmodule Shem.HTTP.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/api", to: Shem.REST.Router
  forward "/", to: Shem.MCP.Router
end
