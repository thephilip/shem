defmodule Shem.MCP.Handlers.CounterfactualRun do
  @spec call(map()) :: {:ok, map()} | {:error, :invalid_args, String.t()}
  def call(%{"session_id" => sid, "fork_event_id" => eid, "variants" => variants} = args)
      when is_binary(sid) and is_binary(eid) and is_list(variants) do
    opts =
      case Map.get(args, "max_turns") do
        n when is_integer(n) and n > 0 -> [max_turns: n]
        _ -> []
      end ++
        case Map.get(args, "deny_actions") do
          deny when is_list(deny) -> [deny_actions: Enum.filter(deny, &is_binary/1)]
          _ -> []
        end

    case Shem.Counterfactual.run(sid, eid, variants, opts) do
      {:ok, res} -> {:ok, res}
      {:error, reason} -> {:error, :invalid_args, describe(reason)}
    end
  end

  def call(_args),
    do:
      {:error, :invalid_args,
       "session_id, fork_event_id, and variants (non-empty list of strings) are required"}

  defp describe(:not_found), do: "session not found"
  defp describe(:fork_event_not_found), do: "no llm_call_completed event at or before fork_event_id"
  defp describe(:invalid_variants), do: "variants must be non-empty strings"

  defp describe(:too_many_variants),
    do: "too many variants (cap: config :shem, :counterfactual, :max_variants)"

  defp describe(other), do: inspect(other)
end
