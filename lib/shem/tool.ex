defmodule Shem.Tool do
  @moduledoc """
  Data contract for a graduated tool. A `%Shem.Tool{}` only exists after a tool
  passes the graduation gate — before that, code is represented as plain strings.
  """

  @enforce_keys [:id, :name, :runtime, :source, :test_source, :graduated_at]
  defstruct [
    :id,
    :name,
    :runtime,
    :source,
    :test_source,
    :graduated_at,
    constraints: [],
    input_schema: %{},
    metadata: %{}
  ]

  @type runtime :: {:beam, module()} | {:port, String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          runtime: runtime(),
          source: String.t(),
          test_source: String.t(),
          constraints: [String.t()],
          input_schema: map(),
          graduated_at: DateTime.t(),
          metadata: map()
        }
end
