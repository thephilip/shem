defmodule Shem.Lab.GraduationGate do
  alias Shem.Lab.{Workspace, Executor, Registry}
  alias Shem.Tool

  @no_property_seed 0.5

  @builtin_languages %{
    "elixir" => :elixir,
    "python" => :python,
    "javascript" => :javascript,
    "go" => :go
  }

  @spec run(String.t(), String.t(), keyword()) ::
          {:ok, Tool.t()}
          | {:error, :compile, String.t()}
          | {:error, :gate, any()}
          | {:error, :timeout}
          | {:error, :language_not_configured, String.t()}
  def run(source, test_source, opts \\ []) do
    lang = Keyword.get(opts, :language, "elixir")
    languages = Application.get_env(:shem, :graduation_languages, @builtin_languages)

    case Map.get(languages, lang) do
      :elixir     -> run_elixir(source, test_source, opts)
      :python     -> Shem.Lab.GraduationGate.Python.run(source, test_source, opts)
      :javascript -> Shem.Lab.GraduationGate.JS.run(source, test_source, opts)
      :go         -> Shem.Lab.GraduationGate.Go.run(source, test_source, opts)
      nil         -> {:error, :language_not_configured, lang}
    end
  end

  defp run_elixir(source, test_source, opts) do
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
          # Property tools earn trust by passing their properties; others get a
          # lightweight single-turn review that refines the default seed. The full
          # red-team loop is opt-in via Shem.Adversarial.start_hardening/1.
          unless property?, do: seed_trust(tool.id, hardening_score(tool))
          {:ok, tool}
        else
          {:error, :compile, reason} -> {:error, :compile, reason}
        end

      {:error, :compile, "safety scan: " <> _ = reason} = err ->
        {:ok, _} = Shem.EventLog.start_session("security")
        Shem.EventLog.append("security", :scan_rejected, %{reason: reason})
        err

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

  defp hardening_score(tool) do
    case Shem.Lab.GraduationGate.Hardening.check(tool) do
      {:ok, score} -> score
      :skip -> @no_property_seed
    end
  end

  defp seed_trust(tool_id, score) do
    Shem.Trust.Store.seed(tool_id, score)
  catch
    :exit, _ -> {:error, :store_down}
  end
end
