defmodule Shem.LLM.Request do
  @enforce_keys [:prompt, :model]
  defstruct [:prompt, :model, :session_id, :system, :messages, options: %{}]

  @type message :: %{role: :user | :assistant | :tool, content: String.t()}

  @type t :: %__MODULE__{
          prompt: String.t(),
          model: atom(),
          options: map(),
          session_id: String.t() | nil,
          system: String.t() | nil,
          messages: [message()] | nil
        }
end
