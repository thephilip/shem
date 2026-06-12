defmodule Shem.TUI.Autocomplete do
  @moduledoc """
  Pure suggestion logic for the slash-command overlay.

  Suggestions match on the command's first token, so `/agent gen` still
  suggests `/agent <preset> <task>` while the user types arguments.
  """

  @type command :: {String.t(), String.t()}

  @spec suggest(String.t(), [command()]) :: [command()]
  def suggest("/" <> _ = buffer, commands) do
    case String.split(buffer, " ", parts: 2) do
      [typed] ->
        Enum.filter(commands, fn {cmd, _desc} ->
          cmd_token = cmd |> String.split(" ", parts: 2) |> hd()
          String.starts_with?(cmd_token, typed)
        end)

      [typed, _args] ->
        Enum.filter(commands, fn {cmd, _desc} ->
          cmd_token = cmd |> String.split(" ", parts: 2) |> hd()
          cmd_token == typed
        end)
    end
  end

  def suggest(_buffer, _commands), do: []

  @spec complete(command()) :: String.t()
  def complete({cmd, _desc}) do
    token = cmd |> String.split(" ", parts: 2) |> hd()
    token <> " "
  end
end
