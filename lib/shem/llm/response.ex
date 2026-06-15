defmodule Shem.LLM.Response do
  @enforce_keys [:tokens_used, :model, :latency_ms]
  defstruct [:content, :tool_calls, :reasoning_content, :tokens_used, :model, :latency_ms]

  @type tool_call :: %{id: String.t(), name: String.t(), args: map()}

  @type t :: %__MODULE__{
          content: String.t() | nil,
          tool_calls: [tool_call()] | nil,
          reasoning_content: String.t() | nil,
          tokens_used: non_neg_integer(),
          model: atom(),
          latency_ms: non_neg_integer()
        }
end
