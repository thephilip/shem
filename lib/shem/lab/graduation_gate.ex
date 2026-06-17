defmodule Shem.Lab.GraduationGate do
  alias Shem.Lab.{Workspace, Executor, Registry}
  alias Shem.Tool

  @no_property_seed 0.5

  @spec run(String.t(), String.t(), keyword()) ::
          {:ok, Tool.t()}
          | {:error, :compile, String.t()}
          | {:error, :gate, any()}
          | {:error, :timeout}
  def run(source, test_source, opts \\ []) do
    description = Keyword.get(opts, :description, "")
    schema      = Keyword.get(opts, :schema, %{})
    constraints = Keyword.get(opts, :constraints, [])

    combined = source <> "\n" <> test_source

    executor_opts =
      case Application.get_env(:shem, :lab_executor_node) do
        nil -> []
        node -> [node: node]
      end

    case Executor.run(combined, fn test_mod -> test_mod.run() end, executor_opts) do
      {:ok, :ok} ->
        with {:ok, module} <- extract_module(source) do
          property? = property_tested?(test_source)
          id = unique_id(module)

          tool = %Tool{
            id: id,
            name: module |> Atom.to_string() |> String.split(".") |> List.last(),
            runtime: {:beam, module},
            source: source,
            test_source: test_source,
            constraints: constraints,
            graduated_at: DateTime.utc_now(),
            metadata: %{
              :property_tested => property?,
              "description"    => description,
              "schema"         => schema
            }
          }

          :ok = Workspace.graduate(tool)
          :ok = Registry.register(tool)
          unless property?, do: seed_trust(tool.id)
          Shem.Adversarial.start_hardening(tool.id)
          {:ok, tool}
        else
          {:error, :compile, reason} -> {:error, :compile, reason}
        end

      {:error, :compile, reason} ->
        {:error, :compile, reason}

      {:error, :runtime, reason} ->
        {:error, :gate, reason}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, :gate, reason}
    end
  end

  defp extract_module(source) do
    case Regex.run(~r/defmodule\s+(\S+)\s+do/, source) do
      [_, name] -> {:ok, Module.concat([name])}
      _ -> {:error, :compile, "could not determine module name from source"}
    end
  end

  defp unique_id(module) do
    base =
      module
      |> Atom.to_string()
      |> String.split(".")
      |> List.last()
      |> Macro.underscore()

    if Registry.lookup(base) == {:error, :not_found} do
      base
    else
      version =
        Enum.find(2..100, fn v ->
          Registry.lookup("#{base}_v#{v}") == {:error, :not_found}
        end)

      "#{base}_v#{version}"
    end
  end

  # The heuristic is the cheap half of the gate: presence of a StreamData
  # invocation. The substantive half is that the property must PASS inside
  # the executor like any other test.
  defp property_tested?(test_source), do: test_source =~ ~r/check_all|StreamData\./

  defp seed_trust(tool_id) do
    Shem.Trust.Store.seed(tool_id, @no_property_seed)
  catch
    :exit, _ -> {:error, :store_down}
  end
end
