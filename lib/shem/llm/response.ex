defmodule Shem.LLM.Response do
  @enforce_keys [:content, :tokens_used, :model, :latency_ms]
  defstruct [:content, :tokens_used, :model, :latency_ms]

  @type t :: %__MODULE__{
          content: String.t(),
          tokens_used: non_neg_integer(),
          model: atom(),
          latency_ms: non_neg_integer()
        }
end
