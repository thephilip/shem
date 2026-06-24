defmodule Shem.LLM.Middleware.OneShot do
  @moduledoc """
  Terminal middleware that returns a pre-known response. Used by the client
  brain to feed a Claude-supplied completion back through the recording
  pipeline (EventLogger etc.) so it is fork/replay-able like any LLM call.
  """
  @behaviour Shem.LLM.Middleware

  @impl true
  def call(_request, opts, _next), do: {:ok, Keyword.fetch!(opts, :response)}

  @impl true
  def stream(_request, opts, chunk_fn, _next) do
    response = Keyword.fetch!(opts, :response)
    if response.content, do: chunk_fn.(response.content)
    {:ok, response}
  end
end
