defmodule Shem.LLM.StubTransport do
  @behaviour Shem.LLM.Middleware

  alias Shem.LLM.StubTransport.Server

  @impl true
  def call(request, opts, _next) do
    server = Keyword.get(opts, :server, Server)
    GenServer.call(server, {:record_call, request})

    case Server.pop(server) do
      {:ok, response} -> response
      :empty -> {:error, :no_stub_response}
    end
  end
end
