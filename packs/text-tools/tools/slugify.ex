defmodule TextTools.Slugify do
  @moduledoc "Convert arbitrary text into a URL-safe slug (lowercase, hyphen-separated)."

  def run(%{"text" => text}) when is_binary(text) do
    slug =
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    %{"slug" => slug}
  end
end
