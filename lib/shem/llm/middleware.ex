defmodule Shem.LLM.Middleware do
  alias Shem.LLM.{Request, Response}

  @type pipeline_result :: {:ok, Response.t()} | {:error, term()}
  @type next :: (Request.t() -> pipeline_result())

  @callback call(request :: Request.t(), opts :: keyword(), next :: next()) ::
              pipeline_result()
end
