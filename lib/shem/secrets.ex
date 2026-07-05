defmodule Shem.Secrets do
  @moduledoc """
  Resolves `{"$secret": "key"}` handles in tool args at execution time by
  invoking the configured provider tool (`config :shem, :secret_provider`).
  Plaintext is spliced into the executor-bound args only — the EventLog and
  model context keep the handle. See the Pack Contract v2 spec.
  """
  alias Shem.Lab.{PortPool, Registry}

  @spec resolve(map()) :: {:ok, map()} | {:error, String.t()}
  def resolve(args) when is_map(args) do
    if has_handle?(args) do
      case Application.get_env(:shem, :secret_provider) do
        nil -> {:error, "args contain {\"$secret\": ...} handles but no :secret_provider is configured"}
        provider -> walk(args, provider)
      end
    else
      {:ok, args}
    end
  end

  defp has_handle?(%{"$secret" => k} = m) when map_size(m) == 1 and is_binary(k), do: true
  defp has_handle?(%{} = m), do: Enum.any?(m, fn {_k, v} -> has_handle?(v) end)
  defp has_handle?(l) when is_list(l), do: Enum.any?(l, &has_handle?/1)
  defp has_handle?(_), do: false

  defp walk(%{"$secret" => key} = m, provider) when map_size(m) == 1 and is_binary(key) do
    read(provider, key)
  end

  defp walk(%{} = m, provider) do
    Enum.reduce_while(m, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case walk(v, provider) do
        {:ok, rv} -> {:cont, {:ok, Map.put(acc, k, rv)}}
        {:error, e} -> {:halt, {:error, e}}
      end
    end)
  end

  defp walk(l, provider) when is_list(l) do
    Enum.reduce_while(l, {:ok, []}, fn v, {:ok, acc} ->
      case walk(v, provider) do
        {:ok, rv} -> {:cont, {:ok, acc ++ [rv]}}
        {:error, e} -> {:halt, {:error, e}}
      end
    end)
  end

  defp walk(other, _provider), do: {:ok, other}

  defp read(provider, key) do
    case Application.get_env(:shem, :secret_resolver_fn) do
      nil ->
        read_via_provider(provider, key)

      fun ->
        case fun.(key) do
          {:ok, v} when is_binary(v) -> {:ok, v}
          {:error, e} -> {:error, "secret resolution failed for #{key}: #{inspect(e)}"}
        end
    end
  end

  defp read_via_provider(provider, key) do
    case Registry.lookup_by_name(provider) do
      {:ok, tool} -> invoke(tool, %{"action" => "read", "key" => key}, key)
      _ -> {:error, "secret provider #{inspect(provider)} is not an installed tool"}
    end
  end

  defp invoke(%{runtime: {:port, runtime_path}} = tool, args, key) do
    language = Map.get(tool.metadata, "language", "python")

    with {:ok, pool} <- PortPool.Supervisor.ensure_started(tool.id, runtime_path, language),
         {:ok, result} <- PortPool.call(pool, args) do
      unwrap(result, key)
    else
      {:error, reason} -> {:error, "secret resolution failed for #{key}: #{inspect(reason)}"}
    end
  end

  defp invoke(%{runtime: {:beam, mod}}, args, key) do
    unwrap(mod.run(args), key)
  rescue
    e -> {:error, "secret resolution failed for #{key}: #{Exception.message(e)}"}
  end

  # Provider contract: a binary, optionally wrapped — {"$sensitive": v} (the
  # provider's own redaction marker) and/or nested under "value" (a provider
  # that returns its full read result, e.g. shem-secret-tools).
  defp unwrap(v, _key) when is_binary(v), do: {:ok, v}
  defp unwrap(%{"$sensitive" => v}, _key) when is_binary(v), do: {:ok, v}
  defp unwrap(%{"value" => v}, key), do: unwrap(v, key)
  defp unwrap(_, key), do: {:error, "secret provider returned a non-string value for #{key}"}
end
