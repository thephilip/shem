defmodule Shem.MCP.Handlers.RecallSearch do
  @spec call(map()) :: {:ok, map()} | {:error, :invalid_args, String.t()}
  def call(%{"query" => query} = args) when is_binary(query) and query != "" do
    limit =
      case Map.get(args, "limit", 5) do
        n when is_integer(n) and n > 0 and n <= 25 -> n
        _ -> 5
      end

    Shem.Recall.search(query, limit)
  end

  def call(_args), do: {:error, :invalid_args, "query (non-empty string) is required"}
end
