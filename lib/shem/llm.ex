defmodule Shem.LLM do
  alias Shem.LLM.{Request, Response}

  @spec complete(Request.t()) :: {:ok, Response.t()} | {:error, term()}
  def complete(%Request{} = request) do
    :telemetry.span([:shem, :llm, :call], %{node: node()}, fn ->
      pipeline = build_pipeline()
      {pipeline.(request), %{}}
    end)
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

  @spec stream_complete(Request.t(), (String.t() -> :ok)) :: {:ok, Response.t()} | {:error, term()}
  def stream_complete(%Request{} = request, chunk_fn) when is_function(chunk_fn, 1) do
    build_stream_pipeline().(request, chunk_fn)
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

  defp build_stream_pipeline do
    pipeline =
      Process.get(:shem_replay_pipeline) ||
        Application.get_env(:shem, :llm_pipeline, [])

    # Each step is fn(req, chunk_fn) -> pipeline_result()
    terminal = fn _req, _chunk_fn -> {:error, :no_terminal} end

    pipeline
    |> normalize_pipeline()
    |> Enum.reverse()
    |> Enum.reduce(terminal, fn {mod, opts}, next ->
      Code.ensure_loaded!(mod)
      if function_exported?(mod, :stream, 4) do
        fn req, chunk_fn -> mod.stream(req, opts, chunk_fn, next) end
      else
        # Fallback: call/3 with a next that threads chunk_fn down
        fn req, chunk_fn -> mod.call(req, opts, fn r -> next.(r, chunk_fn) end) end
      end
    end)
  end

  defp normalize_pipeline(pipeline) do
    Enum.map(pipeline, fn
      {mod, opts} -> {mod, opts}
      mod when is_atom(mod) -> {mod, []}
    end)
  end
end
