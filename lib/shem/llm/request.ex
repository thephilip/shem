defmodule Shem.LLM.Request do
  @enforce_keys [:prompt, :model]
  defstruct [:prompt, :model, :session_id, :system, :messages, :tools, options: %{}]

  @type message :: %{role: :user | :assistant | :tool, content: String.t()}

  @type tool_schema :: %{
          name: String.t(),
          description: String.t(),
          schema: %{type: String.t(), properties: map(), required: [String.t()]}
        }

  @type t :: %__MODULE__{
          prompt: String.t(),
          model: atom(),
          options: map(),
          session_id: String.t() | nil,
          system: String.t() | nil,
          messages: [message()] | nil,
          tools: [tool_schema()] | nil
        }
end
