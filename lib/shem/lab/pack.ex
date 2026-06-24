defmodule Shem.Lab.Pack do
  @moduledoc """
  Install/uninstall git-distributed tool packs. Every tool is re-verified
  through the local graduation gate before it is trusted — installing a pack
  runs third-party code through the same gate that agent-authored tools pass.
  """
  alias Shem.Lab.{GraduationGate, Registry, Workspace}

  @spec install(String.t(), String.t()) ::
          {:ok, %{name: String.t(), installed: [String.t()], replaced: [String.t()], rejected: [map()]}}
          | {:error, term()}
  def install(repo, path \\ ".") do
    if allowed_scheme?(repo) do
      do_install(repo, path)
    else
      {:error, :unsupported_scheme}
    end
  end

  defp do_install(repo, path) do
    tmp = Path.join(System.tmp_dir!(), "shem-pack-#{System.unique_integer([:positive])}")

    try do
      with {:ok, _} <- clone(repo, tmp),
           pack_dir = Path.join(tmp, path),
           {:ok, pack} <- read_pack(pack_dir) do
        {:ok, %{removed: replaced}} = uninstall(pack["name"])
        results = Enum.map(pack["tools"], &install_tool(pack_dir, pack["name"], pack["version"], &1))
        installed = for {:ok, id} <- results, do: id
        rejected = for {:error, id, reason} <- results, do: %{id: id, reason: inspect(reason)}
        {:ok, %{name: pack["name"], installed: installed, replaced: replaced, rejected: rejected}}
      end
    after
      File.rm_rf(tmp)
    end
  end

  defp clone(repo, tmp) do
    case System.cmd(
           "git",
           ["-c", "protocol.ext.allow=never", "-c", "protocol.fd.allow=never",
            "-c", "protocol.file.allow=always",
            "clone", "--depth", "1", "--", repo, tmp],
           stderr_to_stdout: true
         ) do
      {_, 0} -> {:ok, tmp}
      {out, _} -> {:error, {:clone_failed, String.trim(out)}}
    end
  end

  defp allowed_scheme?(repo) do
    String.starts_with?(repo, ["https://", "git://", "ssh://", "git@", "file://"])
  end

  defp read_pack(dir) do
    with {:ok, json} <- File.read(Path.join(dir, "pack.json")),
         {:ok, %{"name" => name, "tools" => tools} = pack}
           when is_binary(name) and is_list(tools) <- Jason.decode(json) do
      {:ok, pack}
    else
      _ -> {:error, :bad_pack}
    end
  end

  defp install_tool(pack_dir, pack_name, pack_version, id) do
    with {:ok, manifest} <- read_manifest(pack_dir, id),
         {:ok, source} <- read_source(pack_dir, id, manifest),
         {:ok, tool} <- gate(source, manifest) do
      case tag_manifest(tool.id, pack_name, pack_version, source) do
        :ok ->
          {:ok, tool.id}

        {:error, reason} ->
          # the gate already wrote + registered this tool; a failed tag would
          # leave it on disk untagged (and thus un-uninstallable), so remove it
          remove_files(tool.id)
          Registry.rescan()
          {:error, id, reason}
      end
    else
      {:error, reason} -> {:error, id, reason}
    end
  end

  defp read_manifest(dir, id) do
    with {:ok, json} <- File.read(Path.join([dir, "tools", "#{id}.json"])),
         {:ok, m} <- Jason.decode(json) do
      {:ok, m}
    else
      _ -> {:error, :bad_manifest}
    end
  end

  defp read_source(dir, id, manifest) do
    ext = if (manifest["language"] || "elixir") == "elixir", do: "ex", else: "py"
    case File.read(Path.join([dir, "tools", "#{id}.#{ext}"])) do
      {:ok, src} -> {:ok, src}
      _ -> {:error, :source_missing}
    end
  end

  defp gate(source, m) do
    opts = [
      language: m["language"] || "elixir",
      description: m["description"] || "",
      schema: m["schema"] || %{},
      constraints: m["constraints"] || []
    ]

    case GraduationGate.run(source, m["test_source"] || "", opts) do
      {:ok, tool} -> {:ok, tool}
      {:error, kind, reason} -> {:error, {kind, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The gate already wrote the manifest via Workspace.graduate/1. Merge the
  # provenance tags into it so uninstall can find this tool later.
  @spec uninstall(String.t()) :: {:ok, %{name: String.t(), removed: [String.t()]}}
  def uninstall(pack_name) do
    ids =
      Workspace.list_graduated()
      |> Enum.flat_map(fn
        {id, path} ->
          case File.read(path) do
            {:ok, json} ->
              case Jason.decode(json) do
                {:ok, %{"pack" => ^pack_name}} -> [id]
                _ -> []
              end

            _ ->
              []
          end

        _ ->
          []
      end)

    Enum.each(ids, &remove_files/1)
    Registry.rescan()
    {:ok, %{name: pack_name, removed: ids}}
  end

  # Manifest (.json), source (.ex/.py) and any :port wrapper share the same base path.
  defp remove_files(id) do
    base = Path.rootname(Workspace.manifest_path(id))
    Enum.each([".json", ".ex", ".py", "_runtime.py"], fn suffix ->
      File.rm(base <> suffix)
    end)
  end

  defp tag_manifest(tool_id, pack_name, pack_version, source) do
    try do
      path = Workspace.manifest_path(tool_id)
      json = File.read!(path)
      # provenance of the installed source bytes (not a verified tamper check)
      hash = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

      merged =
        json
        |> Jason.decode!()
        |> Map.merge(%{"pack" => pack_name, "version" => pack_version, "sha256" => hash})

      File.write!(path, Jason.encode!(merged, pretty: true))
      :ok
    rescue
      e -> {:error, {:tag_failed, Exception.message(e)}}
    end
  end

  @spec list_packs() :: [%{name: String.t(), version: String.t() | nil, tools: [String.t()]}]
  def list_packs do
    Workspace.list_graduated()
    |> Enum.flat_map(fn
      {id, path} ->
        case File.read(path) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, %{"pack" => name} = m} -> [{name, m["version"], id}]
              _ -> []
            end

          _ ->
            []
        end

      _ ->
        []
    end)
    |> Enum.group_by(fn {name, _v, _id} -> name end)
    |> Enum.map(fn {name, entries} ->
      version = entries |> Enum.map(fn {_n, v, _i} -> v end) |> Enum.find(& &1)
      tools = Enum.map(entries, fn {_n, _v, id} -> id end)
      %{name: name, version: version, tools: tools}
    end)
  end
end
