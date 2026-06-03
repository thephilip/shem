defmodule Shem.Tool do
  @moduledoc """
  Data contract for a graduated tool. A `%Shem.Tool{}` only exists after a tool
  passes the graduation gate — before that, code is represented as plain strings.
  """

  @enforce_keys [:id, :name, :module, :source, :test_source, :graduated_at]
  defstruct [
    :id,
    :name,
    :module,
    :source,
    :test_source,
    :graduated_at,
    constraints: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          module: atom(),
          source: String.t(),
          test_source: String.t(),
          constraints: [String.t()],
          graduated_at: DateTime.t(),
          metadata: map()
        }
end
