defmodule Shem.LLM.Request do
  @enforce_keys [:prompt, :model]
  defstruct [:prompt, :model, :session_id, options: %{}]

  @type t :: %__MODULE__{
          prompt: String.t(),
          model: atom(),
          options: map(),
          session_id: String.t() | nil
        }
end
