defmodule Shem.Agent.Turn do
  @moduledoc """
  Pure functions for a single agent turn: parsing LLM response text into
  structured tool calls or a terminal result.

  `parse_response/1` extracts JSON tool call objects from LLM response prose.
  `build_prompt/3` and `step/4` are added in Tasks 3 and 4.
  """

  @spec parse_response(String.t()) ::
          {:tool_calls, [%{tool: String.t(), args: map()}], String.t()}
          | {:done, String.t()}
  def parse_response(content) do
    pattern = ~r/\{(?:[^{}]|\{[^{}]*\})*\}/

    tool_calls =
      Regex.scan(pattern, content)
      |> Enum.map(&hd/1)
      |> Enum.flat_map(fn json_str ->
        case Jason.decode(json_str) do
          {:ok, %{"tool" => tool, "args" => args}} when is_binary(tool) and is_map(args) ->
            [%{tool: tool, args: args}]

          {:ok, %{"tool" => tool}} when is_binary(tool) ->
            [%{tool: tool, args: %{}}]

          _ ->
            []
        end
      end)

    case tool_calls do
      [] -> {:done, content}
      calls -> {:tool_calls, calls, content}
    end
  end
end
