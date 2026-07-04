defmodule Shem.Attest do
  @moduledoc """
  Export a recorded session as a self-verifying bundle (ROADMAP Phase 4).

  Read-only: it never mutates the log and never halts — it runs inside the live
  node under `rpc`. See docs/superpowers/specs/2026-07-03-attest-design.md for
  the two-head trust model (portable_head verified by verify.py; beam_head is
  the live chain anchor for cross-check with Shem).
  """

  alias Shem.Attest.CanonicalJSON
  alias Shem.EventLog
  alias Shem.Lab.{Languages, Registry}

  @spec build(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def build(session_id, opts \\ []) do
    out = Keyword.get(opts, :out, File.cwd!())

    with {:ok, _kind, _n} <- verify(session_id),
         {:ok, events} <- EventLog.read_session_events(session_id) do
      digest =
        case EventLog.get_digest(session_id) do
          {:ok, d} -> d
          _ -> nil
        end

      lines = Enum.map(events, &CanonicalJSON.encode(event_view(&1)))
      seed = (digest && digest.portable_anchor) || portable_genesis(session_id)
      head = Enum.reduce(lines, seed, &portable_next(&2, &1))
      beam_head = events |> List.last() |> then(& &1 && &1.hash)
      tools = collect_tools(events)

      dir = Path.join(out, "attest-#{session_id}-#{String.slice(head, 0, 8)}")
      write_bundle(dir, session_id, events, lines, head, beam_head, tools, digest)
      {:ok, dir}
    end
  end

  defp verify(session_id) do
    case EventLog.verify_chain(session_id) do
      {:ok, kind, n} -> {:ok, kind, n}
      {:error, :not_found} -> {:error, :not_found}
      {:error, broken} -> {:error, {:chain_broken, broken}}
    end
  end

  # The exact fields Chain.canonical/1 commits to — no seq, no hash.
  @doc false
  def event_view(e) do
    %{
      id: e.id,
      session_id: e.session_id,
      type: e.type,
      payload: e.payload,
      timestamp: DateTime.to_iso8601(e.timestamp),
      parent_id: e.parent_id
    }
  end

  @spec portable_genesis(String.t()) :: String.t()
  def portable_genesis(session_id),
    do: :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower)

  @spec portable_next(String.t(), binary()) :: String.t()
  def portable_next(prev_hex, line),
    do: :crypto.hash(:sha256, prev_hex <> line) |> Base.encode16(case: :lower)

  defp collect_tools(events) do
    events
    |> Enum.filter(&(&1.type == :agent_tool_called))
    |> Enum.map(& &1.payload[:tool])
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&resolve_tool/1)
  end

  # Events record the model-facing tool NAME (the manifest `name`), not the
  # tool id, so resolve by name, not id.
  defp resolve_tool(name) do
    case Registry.lookup_by_name(name) do
      {:ok, tool} ->
        sha = :crypto.hash(:sha256, tool.source) |> Base.encode16(case: :lower)
        %{name: name, sha256: sha, runtime: runtime_tag(tool.runtime),
          ext: ext_for(tool.runtime), source: tool.source, status: "present"}

      {:error, :not_found} ->
        %{name: name, sha256: nil, runtime: nil, ext: nil, source: nil, status: "missing"}
    end
  end

  defp runtime_tag({:beam, _}), do: "beam"
  defp runtime_tag({:port, rt}), do: rt

  defp ext_for({:beam, _}), do: "ex"
  defp ext_for({:port, rt}), do: Languages.ext(rt)

  defp write_bundle(dir, session_id, events, lines, head, beam_head, tools, digest) do
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "tools"))

    File.write!(Path.join(dir, "events.jsonl"), Enum.map(lines, &[&1, "\n"]))

    sha_lines =
      for t <- tools, t.status == "present" do
        file = "#{t.sha256}.#{t.ext}"
        File.write!(Path.join([dir, "tools", file]), t.source)
        "#{t.sha256}  tools/#{file}\n"
      end

    File.write!(Path.join(dir, "tools.sha256"), sha_lines)

    manifest = %{
      shem_version: Application.spec(:shem, :vsn) |> to_string(),
      session_id: session_id,
      event_count: length(events),
      exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      genesis: portable_genesis(session_id),
      portable_head: head,
      beam_head: beam_head,
      tools: Enum.map(tools, &Map.take(&1, [:name, :sha256, :runtime, :status]))
    }

    manifest =
      if digest do
        Map.put(manifest, :gc, %{
          covers_to_seq: digest.covers_to_seq,
          pruned_count: digest.count,
          portable_anchor: digest.portable_anchor,
          beam_anchor: digest.beam_anchor,
          pruned_at: DateTime.to_iso8601(digest.pruned_at)
        })
      else
        manifest
      end

    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest, pretty: true))

    File.cp!(priv("verify.py"), Path.join(dir, "verify.py"))
    File.cp!(priv("README.txt"), Path.join(dir, "README.txt"))
  end

  defp priv(name), do: Path.join(:code.priv_dir(:shem) |> to_string(), "attest/#{name}")

  @doc """
  Live-node (`rpc`) entry for `shem attest` while Shem is RUNNING. Runs INSIDE the
  daemon, so it must never halt. Release `rpc` always exits 0 and hides the return
  value, but IO from here reaches the caller — so it prints a stable sentinel line
  followed by the bundle dir on success, or an error to stderr, and the shell
  wrapper keys the exit code on the sentinel.
  """
  @spec rpc_report(String.t(), String.t()) :: :ok
  def rpc_report(session_id, out) do
    case build(session_id, out: out) do
      {:ok, dir} ->
        IO.puts("SHEM_ATTEST_OK")
        IO.puts(dir)

      {:error, reason} ->
        IO.puts(:stderr, "attest of #{session_id} failed: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Ephemeral entry for `shem attest` when Shem is STOPPED (and `mix shem.attest`).
  Boots the app headless, writes the bundle, returns an exit code. The live
  (`rpc`) path calls `build/2` directly and must NOT use this (no halt/boot).
  """
  @spec cli(String.t(), String.t()) :: 0 | 2
  def cli(session_id, out) do
    Application.put_env(:shem, :start_tui, false)
    Application.put_env(:shem, :start_cluster, false)
    Application.put_env(:shem, :mcp_port, 0)
    {:ok, _} = Application.ensure_all_started(:shem)

    case build(session_id, out: out) do
      {:ok, dir} ->
        IO.puts("attest bundle written: #{dir}")
        IO.puts("verify with:  python3 #{Path.join(dir, "verify.py")} #{dir}")
        0

      {:error, reason} ->
        IO.puts(:stderr, "attest of #{session_id} failed: #{inspect(reason)}")
        2
    end
  end
end
