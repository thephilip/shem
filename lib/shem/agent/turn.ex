defmodule Shem.Agent.Turn do
  @moduledoc """
  Pure functions for a single agent turn: parsing LLM response text into
  structured tool calls or a terminal result.

  `parse_response/1` extracts JSON tool call objects from LLM response prose.
  `build_prompt/3` and `step/4` are added in Tasks 3 and 4.
  """

  alias Shem.Agent.Config
  alias Shem.LLM
  alias Shem.LLM.{Request, Response}

  @spec strip_thinking(String.t()) :: String.t()
  def strip_thinking(content) do
    Regex.replace(~r/<think>.*?<\/think>/s, content, "") |> String.trim()
  end

  @spec parse_response(String.t()) ::
          {:tool_calls, [%{id: nil, name: String.t(), args: map()}], String.t()}
          | {:done, String.t()}
  def parse_response(content) do
    tool_calls =
      scan_json_objects(content)
      |> Enum.flat_map(fn json_str ->
        case Jason.decode(json_str) do
          {:ok, %{"tool" => tool, "args" => args}} when is_binary(tool) and is_map(args) ->
            [%{id: nil, name: tool, args: args}]

          {:ok, %{"tool" => tool}} when is_binary(tool) ->
            [%{id: nil, name: tool, args: %{}}]

          _ ->
            []
        end
      end)

    case tool_calls do
      [] -> {:done, content}
      calls -> {:tool_calls, calls, content}
    end
  end

  # String-aware balanced-brace scanner.
  # Finds all top-level {...} spans in `content`, correctly skipping braces
  # that appear inside JSON string literals and honoring backslash escapes.
  # Returns a list of binary spans (candidates for Jason.decode).
  defp scan_json_objects(content) do
    scan_json_objects(content, 0, [])
  end

  defp scan_json_objects(content, pos, acc) do
    case find_open_brace(content, pos) do
      :eof ->
        Enum.reverse(acc)

      start ->
        case scan_object(content, start + 1, 1) do
          {:ok, end_pos} ->
            span = binary_part(content, start, end_pos - start + 1)
            scan_json_objects(content, end_pos + 1, [span | acc])

          :unbalanced ->
            # Resume scanning one byte past the opening brace
            scan_json_objects(content, start + 1, acc)
        end
    end
  end

  # Find the next '{' at or after `pos` in `content` (depth-0 only).
  defp find_open_brace(content, pos) do
    if pos >= byte_size(content) do
      :eof
    else
      case binary_part(content, pos, 1) do
        "{" -> pos
        _ -> find_open_brace(content, pos + 1)
      end
    end
  end

  # Walk content from `pos` with `depth` brace depth, tracking string state.
  # Returns {:ok, end_byte_pos} when depth reaches 0, or :unbalanced at EOF.
  defp scan_object(content, pos, depth) do
    scan_object(content, pos, depth, false)
  end

  defp scan_object(_content, pos, _depth, _in_string) when pos < 0 do
    :unbalanced
  end

  defp scan_object(content, pos, depth, in_string) do
    if pos >= byte_size(content) do
      :unbalanced
    else
      byte = binary_part(content, pos, 1)
      cond do
        # Inside a string: handle escape sequences
        in_string and byte == "\\" ->
          # Skip the next byte (escape handling)
          scan_object(content, pos + 2, depth, true)

        # Inside a string: end of string
        in_string and byte == "\"" ->
          scan_object(content, pos + 1, depth, false)

        # Inside a string: any other byte — skip it
        in_string ->
          scan_object(content, pos + 1, depth, true)

        # Outside string: start of string
        byte == "\"" ->
          scan_object(content, pos + 1, depth, true)

        # Outside string: open brace — increase depth
        byte == "{" ->
          scan_object(content, pos + 1, depth + 1, false)

        # Outside string: close brace — decrease depth
        byte == "}" ->
          if depth == 1 do
            {:ok, pos}
          else
            scan_object(content, pos + 1, depth - 1, false)
          end

        true ->
          scan_object(content, pos + 1, depth, false)
      end
    end
  end

  @spec build_prompt(String.t(), [map()], [map()]) :: String.t()
  def build_prompt(system_prompt, tools_manifest, history) do
    tool_lines =
      tools_manifest
      |> Enum.map(fn %{name: name, description: desc} = t ->
        "- #{name} [trust: #{t[:trust] || :unrated}]: #{desc}"
      end)
      |> Enum.join("\n")

    history_lines =
      history
      |> Enum.map(fn
        %{role: :user, content: c} -> "User: #{c}"
        %{role: :assistant, content: c} -> "Assistant: #{c}"
        %{role: :tool, content: c} -> c
      end)
      |> Enum.join("\n\n")

    """
    #{system_prompt}

    You have access to tools. To call a tool, output JSON anywhere in your response:
    {"tool": "<name>", "args": {"key": "value"}}

    If a tool takes no args use: {"tool": "<name>", "args": {}}

    When your task is complete, respond with plain text only — no JSON tool call.

    Available tools (prefer higher trust; low-trust tools may be blocked):
    #{tool_lines}

    ---

    #{history_lines}

    Assistant:\
    """
  end

  @spec build_request(atom(), String.t(), [map()], [map()]) :: Request.t()
  def build_request(model, system_prompt, tools_manifest, history) do
    prompt = build_prompt(system_prompt, tools_manifest, history)

    messages =
      case build_messages(history) do
        [] -> nil
        msgs -> msgs
      end

    tools =
      case Enum.map(tools_manifest, &Map.take(&1, [:name, :description, :schema])) do
        [] -> nil
        ts -> ts
      end

    %Request{prompt: prompt, model: model, system: system_prompt, messages: messages, tools: tools}
  end

  defp build_messages(history) do
    Enum.map(history, fn
      %{role: :user, content: c} ->
        %{role: :user, content: c}

      %{role: :assistant, content: c, tool_calls: calls} ->
        %{role: :assistant, content: c, tool_calls: calls}

      %{role: :assistant, content: c} ->
        %{role: :assistant, content: c}

      %{role: :tool, content: c, tool_call_id: id} ->
        %{role: :tool, content: c, tool_call_id: id}

      %{role: :tool, content: c} ->
        %{role: :tool, content: c}
    end)
  end

  @spec stream_step(Config.t(), String.t(), [map()], [map()]) ::
          {:tool_calls, [%{id: String.t() | nil, name: String.t(), args: map()}], String.t(), String.t() | nil}
          | {:done, String.t(), String.t() | nil}
          | {:error, term()}
  def stream_step(%Config{} = config, session_id, history, tools_manifest) do
    chunk_fn = fn token ->
      Enum.each(:pg.get_members(:shem_streams, session_id), fn pid ->
        send(pid, {:stream_chunk, session_id, token})
      end)
    end

    request =
      config.model
      |> build_request(config.system_prompt, tools_manifest, history)
      |> Map.put(:session_id, session_id)

    case LLM.stream_complete(request, chunk_fn) do
      {:ok, %Response{tool_calls: [_ | _] = calls, content: content, reasoning_content: rc}} ->
        {:tool_calls, calls, content || "", rc}

      {:ok, %Response{content: content, reasoning_content: rc}} ->
        case (content || "") |> strip_thinking() |> parse_response() do
          {:done, c} -> {:done, c, rc}
          {:tool_calls, calls, raw} -> {:tool_calls, calls, raw, rc}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec step(Config.t(), String.t(), [map()], [map()]) ::
          {:tool_calls, [%{id: String.t() | nil, name: String.t(), args: map()}], String.t(), String.t() | nil}
          | {:done, String.t(), String.t() | nil}
          | {:error, term()}
  def step(%Config{} = config, session_id, history, tools_manifest) do
    request =
      config.model
      |> build_request(config.system_prompt, tools_manifest, history)
      |> Map.put(:session_id, session_id)

    case LLM.complete(request) do
      {:ok, %Response{tool_calls: [_ | _] = calls, content: content, reasoning_content: rc}} ->
        {:tool_calls, calls, content || "", rc}

      {:ok, %Response{content: content, reasoning_content: rc}} ->
        case (content || "") |> strip_thinking() |> parse_response() do
          {:done, c} -> {:done, c, rc}
          {:tool_calls, calls, raw} -> {:tool_calls, calls, raw, rc}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
