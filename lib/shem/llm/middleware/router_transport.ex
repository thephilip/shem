defmodule Shem.LLM.Middleware.RouterTransport do
  @behaviour Shem.LLM.Middleware

  @impl true
  def call(request, opts, _next) do
    resolve_fn = Keyword.get(opts, :resolve_fn, &Shem.LLM.Router.resolve/1)

    case resolve_fn.(request.model) do
      {:error, reason} ->
        {:error, {:router, reason}}

      {transport_module, transport_opts} ->
        # Only terminal transports (those that ignore `next`) may appear in the Router's backend map.
        transport_module.call(request, transport_opts, fn _ -> {:error, :no_next} end)
    end
  end

  @impl true
  def stream(request, opts, chunk_fn, _next) do
    resolve_fn = Keyword.get(opts, :resolve_fn, &Shem.LLM.Router.resolve/1)

    case resolve_fn.(request.model) do
      {:error, reason} ->
        {:error, {:router, reason}}

      {transport_module, transport_opts} ->
        transport_module.stream(
          request,
          transport_opts,
          chunk_fn,
          fn _req, _cf -> {:error, :no_next} end
        )
    end
  end
end
