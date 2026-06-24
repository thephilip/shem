defmodule TextTools.WordCount do
  @moduledoc "Count words, characters (graphemes), and lines in a block of text."

  def run(%{"text" => text}) when is_binary(text) do
    %{
      "words" => text |> String.split(~r/\s+/, trim: true) |> length(),
      "chars" => String.length(text),
      "lines" => text |> String.split("\n") |> length()
    }
  end
end
