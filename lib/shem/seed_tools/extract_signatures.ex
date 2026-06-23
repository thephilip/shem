defmodule Shem.SeedTools.ExtractSignatures do
  @moduledoc """
  Extract `def`/`defp` signatures (name/arity) from Elixir source without reading
  the bodies — learn a module's API at a fraction of the tokens of a full read.
  Parses only (`Code.string_to_quoted`); never compiles the input.
  """
  @external_resource __ENV__.file
  @source File.read!(__ENV__.file)

  def run(%{"source" => source}) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> %{"signatures" => collect(ast)}
      {:error, _} -> %{"error" => "could not parse source"}
    end
  end

  defp collect(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _, [{:when, _, [{name, _, args} | _]} | _]} = node, acc
        when kind in [:def, :defp] and is_atom(name) ->
          {node, [sig(kind, name, args) | acc]}

        {kind, _, [{name, _, args} | _]} = node, acc
        when kind in [:def, :defp] and is_atom(name) ->
          {node, [sig(kind, name, args) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp sig(kind, name, args) do
    arity = if is_list(args), do: length(args), else: 0
    "#{kind} #{name}/#{arity}"
  end

  def tool do
    %Shem.Tool{
      id: "extract_signatures",
      name: "ExtractSignatures",
      runtime: {:beam, __MODULE__},
      source: @source,
      test_source: "",
      input_schema: %{"source" => %{"type" => "string"}},
      graduated_at: ~U[2026-06-22 00:00:00Z],
      metadata: %{"description" => "Extract def/defp signatures (name/arity) from Elixir source without its bodies."}
    }
  end
end
