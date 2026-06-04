defmodule Shem.LLM do
  alias Shem.LLM.{Request, Response}

  @spec complete(Request.t()) :: {:ok, Response.t()} | {:error, term()}
  def complete(%Request{} = request) do
    pipeline = build_pipeline()
    pipeline.(request)
  end

  @doc """
  Phase 5 MVP: invokes `complete/1` and calls `callback` once with the full response content.
  Full chunked streaming is Phase 6.
  """
  @spec stream(Request.t(), (String.t() -> any())) :: {:ok, Response.t()} | {:error, term()}
  def stream(%Request{} = request, callback) when is_function(callback, 1) do
    case complete(request) do
      {:ok, response} ->
        callback.(response.content)
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_pipeline do
    pipeline =
      Process.get(:shem_replay_pipeline) ||
        Application.get_env(:shem, :llm_pipeline, [])

    terminal = fn _req -> {:error, :no_terminal} end

    pipeline
    |> normalize_pipeline()
    |> Enum.reverse()
    |> Enum.reduce(terminal, fn {mod, opts}, next ->
      fn req -> mod.call(req, opts, next) end
    end)
  end

  defp normalize_pipeline(pipeline) do
    Enum.map(pipeline, fn
      {mod, opts} -> {mod, opts}
      mod when is_atom(mod) -> {mod, []}
    end)
  end
end
