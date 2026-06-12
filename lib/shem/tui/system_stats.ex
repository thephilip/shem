defmodule Shem.TUI.SystemStats do
  @moduledoc """
  Host metrics for the dashboard, via :os_mon (cpu_sup + memsup).

  Every accessor degrades to nil instead of raising — os_mon may be missing
  on some platforms, still warming up, or its servers may be restarting.
  """

  @type t :: %{
          cpu: number() | nil,
          mem_used_mb: non_neg_integer() | nil,
          mem_total_mb: non_neg_integer() | nil
        }

  @spec empty() :: t()
  def empty, do: %{cpu: nil, mem_used_mb: nil, mem_total_mb: nil}

  @spec collect() :: t()
  def collect do
    %{cpu: cpu_percent(), mem_used_mb: nil, mem_total_mb: nil}
    |> put_memory()
  end

  @spec format(t()) :: String.t()
  def format(stats) do
    cpu =
      case stats.cpu do
        nil -> "--"
        n -> "#{n}%"
      end

    mem =
      case stats do
        %{mem_used_mb: used, mem_total_mb: total} when is_integer(used) and is_integer(total) ->
          "#{used}/#{total} MB"

        _ ->
          "--"
      end

    "CPU: #{cpu}   MEM: #{mem}"
  end

  defp cpu_percent do
    case :cpu_sup.util() do
      util when is_number(util) -> Float.round(util * 1.0, 1)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp put_memory(stats) do
    case :memsup.get_system_memory_data() do
      data when is_list(data) ->
        total = Keyword.get(data, :total_memory) || Keyword.get(data, :system_total_memory)
        avail = Keyword.get(data, :available_memory) || Keyword.get(data, :free_memory)

        case total do
          t when is_integer(t) ->
            used = t - (avail || 0)
            %{stats | mem_used_mb: div(used, 1_048_576), mem_total_mb: div(t, 1_048_576)}

          _ ->
            stats
        end

      _ ->
        stats
    end
  rescue
    _ -> stats
  catch
    :exit, _ -> stats
  end
end
