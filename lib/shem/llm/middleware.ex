defmodule Shem.LLM.Middleware do
  alias Shem.LLM.{Request, Response}

  @type pipeline_result :: {:ok, Response.t()} | {:error, term()}
  @type next :: (Request.t() -> pipeline_result())
  @type chunk_fn :: (String.t() -> :ok)
  @type stream_next :: (Request.t(), chunk_fn() -> pipeline_result())

  @callback call(request :: Request.t(), opts :: keyword(), next :: next()) ::
              pipeline_result()

  @callback stream(
              request :: Request.t(),
              opts :: keyword(),
              chunk_fn :: chunk_fn(),
              next :: stream_next()
            ) :: {:ok, Response.t()} | {:error, term()}

  @optional_callbacks stream: 4
end
