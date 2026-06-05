defmodule Shem.TUI.CommandDispatch do
  @spec parse(String.t()) ::
          {:start_agent, String.t(), String.t()}
          | {:stop_agent}
          | {:list_agents}
          | {:redteam, String.t()}
          | {:error, String.t()}
  def parse(""), do: {:error, "empty input"}

  def parse("/" <> rest) do
    parts = String.split(rest, " ", trim: true)

    case parts do
      ["agent", preset | task_parts] when task_parts != [] ->
        {:start_agent, preset, Enum.join(task_parts, " ")}

      ["agent" | _] ->
        {:error, "usage: /agent <preset> <task>"}

      ["stop"] ->
        {:stop_agent}

      ["agents"] ->
        {:list_agents}

      ["redteam" | tool_parts] ->
        name = String.trim(Enum.join(tool_parts, " "))
        if name == "" do
          {:error, "usage: /redteam <tool_name>"}
        else
          {:redteam, name}
        end

      _ ->
        {:error, "unknown command: /#{rest}"}
    end
  end

  def parse(text) do
    trimmed = String.trim(text)
    if trimmed == "", do: {:error, "empty input"}, else: {:start_agent, "general", trimmed}
  end
end
