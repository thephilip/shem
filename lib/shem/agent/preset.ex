defmodule Shem.Agent.Preset do
  @builtin_presets [
    %{
      name: "general",
      system_prompt: "You are a helpful assistant. Think step by step and use available tools to complete the task. When finished, respond with plain text only.",
      tools: :all
    },
    %{
      name: "coding",
      system_prompt: "You are an expert Elixir and OTP engineer. Read the relevant code and understand the context before making changes. Use write_file to edit files, shell to run tests (e.g. mix test), and read_file/list_dir to explore. Prefer small, verified changes over large rewrites. When finished, confirm what was done.",
      tools: :all
    },
    %{
      name: "explore",
      system_prompt: "You are a read-only code explorer. Your job is to understand and explain code, not to modify it. Use read_file, list_dir, and shell (for grep/find) to explore the codebase. Do not use write_file or write_tool.",
      tools: ["read_file", "list_dir", "shell"]
    }
  ]

  @spec resolve(String.t()) ::
          {:ok, %{system_prompt: String.t(), tools: :all | [String.t()]}}
          | {:error, :not_found}
  def resolve(name) do
    presets = Application.get_env(:shem, :agent_presets, @builtin_presets)

    case Enum.find(presets, &(&1.name == name)) do
      nil -> {:error, :not_found}
      preset -> {:ok, Map.take(preset, [:system_prompt, :tools])}
    end
  end

  @spec all() :: [map()]
  def all do
    Application.get_env(:shem, :agent_presets, @builtin_presets)
  end
end
