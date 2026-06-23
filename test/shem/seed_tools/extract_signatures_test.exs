defmodule Shem.SeedTools.ExtractSignaturesTest do
  use ExUnit.Case, async: true
  alias Shem.SeedTools.ExtractSignatures

  test "extracts def/defp signatures with arity, multiple clauses, guards" do
    source = """
    defmodule Demo do
      def run(args), do: handle(args)
      def run(a, b), do: {a, b}
      def parse(s) when is_binary(s), do: String.trim(s)
      defp handle(x), do: x
      defp lab_dir, do: :ok
    end
    """

    assert ExtractSignatures.run(%{"source" => source}) == %{
             "signatures" => [
               "def run/1",
               "def run/2",
               "def parse/1",
               "defp handle/1",
               "defp lab_dir/0"
             ]
           }
  end

  test "unparseable source returns an error map" do
    assert ExtractSignatures.run(%{"source" => "defmodule Broken do def"}) == %{
             "error" => "could not parse source"
           }
  end

  test "tool/0 advertises a beam runtime and string schema" do
    tool = ExtractSignatures.tool()
    assert tool.id == "extract_signatures"
    assert tool.runtime == {:beam, ExtractSignatures}
    assert tool.input_schema == %{"source" => %{"type" => "string"}}
  end
end
