defmodule Shem.MCP.Handlers.RecallContext do
  @spec call(map()) :: {:ok, map()} | {:error, atom(), String.t()} | {:error, atom()}
  def call(%{"session_id" => sid, "event_id" => eid} = args)
      when is_binary(sid) and is_binary(eid) do
    radius =
      case Map.get(args, "radius", 3) do
        n when is_integer(n) and n >= 0 and n <= 50 -> n
        _ -> 3
      end

    Shem.Recall.context(sid, eid, radius)
  end

  def call(_args), do: {:error, :invalid_args, "session_id and event_id are required"}
end
