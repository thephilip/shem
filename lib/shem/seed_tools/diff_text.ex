defmodule Shem.SeedTools.DiffText do
  @moduledoc "Unified-style line diff between two strings. Deterministic, stdlib only."
  @external_resource __ENV__.file
  @source File.read!(__ENV__.file)

  def run(%{"a" => a, "b" => b}) when is_binary(a) and is_binary(b) do
    diff =
      List.myers_difference(String.split(a, "\n"), String.split(b, "\n"))
      |> Enum.flat_map(fn
        {:eq, lines} -> Enum.map(lines, &(" " <> &1))
        {:del, lines} -> Enum.map(lines, &("-" <> &1))
        {:ins, lines} -> Enum.map(lines, &("+" <> &1))
      end)
      |> Enum.join("\n")

    %{"diff" => diff}
  end

  def tool do
    %Shem.Tool{
      id: "diff_text",
      name: "DiffText",
      runtime: {:beam, __MODULE__},
      source: @source,
      test_source: "",
      input_schema: %{"a" => %{"type" => "string"}, "b" => %{"type" => "string"}},
      graduated_at: ~U[2026-06-22 00:00:00Z],
      metadata: %{"description" => "Unified-style line diff between two strings."}
    }
  end
end
