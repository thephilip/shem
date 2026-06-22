defmodule Shem.SeedTools.DiffTextTest do
  use ExUnit.Case, async: true
  alias Shem.SeedTools.DiffText

  test "marks changed, added, removed lines" do
    %{"diff" => diff} = DiffText.run(%{"a" => "a\nb\nc", "b" => "a\nx\nc"})
    assert diff == " a\n-b\n+x\n c"
  end

  test "tool/0 advertises a beam runtime and string schema" do
    tool = DiffText.tool()
    assert tool.id == "diff_text"
    assert tool.runtime == {:beam, DiffText}
    assert tool.input_schema == %{"a" => %{"type" => "string"}, "b" => %{"type" => "string"}}
  end
end
