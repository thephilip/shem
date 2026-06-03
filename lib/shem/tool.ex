defmodule Shem.Tool do
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
