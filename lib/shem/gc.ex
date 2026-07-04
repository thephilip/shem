defmodule Shem.GC do
  @moduledoc """
  CLI entries for `shem gc <session_id> [--keep N]` (ROADMAP Phase 4).

  Mutating, unlike attest — but safe against a live session because the live
  path runs INSIDE the daemon via `rpc`, and the stopped path only runs after
  the shell wrapper confirmed the daemon is down. `cli/2` (the mutating twin,
  including `mix shem.gc`) additionally probes for a live daemon before
  touching disk, because `:dets` has no inter-OS-process locking and a
  concurrent daemon write could silently corrupt the file.
  """

  alias Shem.EventLog

  defp keep(nil), do: default_keep()
  defp keep(n), do: n

  defp default_keep do
    case Application.get_env(:shem, :gc, [])[:keep_events] do
      n when is_integer(n) -> n
      _ -> 100_000
    end
  end

  defp report(session_id, k) do
    case EventLog.gc(session_id, k) do
      {:ok, :noop} ->
        {:ok, "nothing to prune (at or under #{k} events)"}

      {:ok, %{pruned: p, total_pruned: t, kept: kept}} ->
        {:ok, "pruned #{p} events this pass (#{t} total), kept #{kept}, digest intact"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Live-node (`rpc`) entry — release rpc always exits 0 and hides return values,
  so print the SHEM_GC_OK sentinel and let the shell wrapper key the exit code
  on it (same dance as Shem.Attest.rpc_report/2).
  """
  @spec rpc_report(String.t(), pos_integer() | nil) :: :ok
  def rpc_report(session_id, keep_arg) do
    case report(session_id, keep(keep_arg)) do
      {:ok, line} ->
        IO.puts("SHEM_GC_OK")
        IO.puts(line)

      {:error, reason} ->
        IO.puts(:stderr, "gc of #{session_id} failed: #{inspect(reason)}")
    end

    :ok
  end

  @doc "Ephemeral entry while Shem is STOPPED (and `mix shem.gc`)."
  @spec cli(String.t(), pos_integer() | nil) :: 0 | 2
  def cli(session_id, keep_arg) do
    port = guard_port()

    if daemon_running?(port) do
      IO.puts(
        :stderr,
        "a Shem daemon appears to be running on port #{port} — run `shem gc` against the live daemon instead, or stop it first"
      )

      2
    else
      Application.put_env(:shem, :start_tui, false)
      Application.put_env(:shem, :start_cluster, false)
      Application.put_env(:shem, :mcp_port, 0)
      {:ok, _} = Application.ensure_all_started(:shem)

      case report(session_id, keep(keep_arg)) do
        {:ok, line} ->
          IO.puts(line)
          0

        {:error, reason} ->
          IO.puts(:stderr, "gc of #{session_id} failed: #{inspect(reason)}")
          2
      end
    end
  end

  defp guard_port do
    case System.get_env("SHEM_PORT") do
      nil -> 4000
      p -> String.to_integer(p)
    end
  end

  @doc false
  @spec daemon_running?(pos_integer()) :: boolean()
  def daemon_running?(port) do
    {:ok, _} = Application.ensure_all_started(:inets)
    url = ~c"http://127.0.0.1:#{port}/api/health"

    case :httpc.request(:get, {url, []}, [timeout: 1_000], []) do
      {:ok, {{_, 200, _}, _headers, _body}} -> true
      _ -> false
    end
  end
end
