defmodule Shem.TUI.CommandDispatch do
  @spec parse(String.t()) ::
          {:start_agent, String.t(), String.t()}
          | {:stop_agent}
          | {:list_agents}
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

      _ ->
        {:error, "unknown command: /#{rest}"}
    end
  end

  def parse(text), do: {:start_agent, "general", text}
end
