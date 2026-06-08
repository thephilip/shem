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
    pattern = ~r/\{(?:[^{}]|\{[^{}]*\})*\}/

    tool_calls =
      Regex.scan(pattern, content)
      |> Enum.map(&hd/1)
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

  @spec build_prompt(String.t(), [map()], [map()]) :: String.t()
  def build_prompt(system_prompt, tools_manifest, history) do
    tool_lines =
      tools_manifest
      |> Enum.map(fn %{name: name, description: desc} -> "- #{name}: #{desc}" end)
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

    Available tools:
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
          {:tool_calls, [%{id: String.t() | nil, name: String.t(), args: map()}], String.t()}
          | {:done, String.t()}
          | {:error, term()}
  def stream_step(%Config{} = config, session_id, history, tools_manifest) do
    chunk_fn = fn token ->
      Registry.dispatch(Shem.StreamRegistry, session_id, fn entries ->
        Enum.each(entries, fn {pid, _} -> send(pid, {:stream_chunk, session_id, token}) end)
      end)
    end

    request =
      config.model
      |> build_request(config.system_prompt, tools_manifest, history)
      |> Map.put(:session_id, session_id)

    case LLM.stream_complete(request, chunk_fn) do
      {:ok, %Response{tool_calls: [_ | _] = calls, content: content}} ->
        {:tool_calls, calls, content || ""}

      {:ok, %Response{content: content}} ->
        (content || "") |> strip_thinking() |> parse_response()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec step(Config.t(), String.t(), [map()], [map()]) ::
          {:tool_calls, [%{id: String.t() | nil, name: String.t(), args: map()}], String.t()}
          | {:done, String.t()}
          | {:error, term()}
  def step(%Config{} = config, session_id, history, tools_manifest) do
    request =
      config.model
      |> build_request(config.system_prompt, tools_manifest, history)
      |> Map.put(:session_id, session_id)

    case LLM.complete(request) do
      {:ok, %Response{tool_calls: [_ | _] = calls, content: content}} ->
        {:tool_calls, calls, content || ""}

      {:ok, %Response{content: content}} ->
        (content || "") |> strip_thinking() |> parse_response()

      {:error, reason} ->
        {:error, reason}
    end
  end
end
