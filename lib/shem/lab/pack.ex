defmodule Shem.Lab.Pack do
  @moduledoc """
  Install/uninstall git-distributed tool packs. Every tool is re-verified
  through the local graduation gate before it is trusted — installing a pack
  runs third-party code through the same gate that agent-authored tools pass.
  """
  alias Shem.Lab.{GraduationGate, Registry, Workspace}

  @spec install(String.t(), String.t(), keyword()) ::
          {:ok, %{name: String.t(), installed: [String.t()], replaced: [String.t()], rejected: [map()]}}
          | {:error, term()}
  def install(repo, path \\ ".", opts \\ []) do
    if allowed_scheme?(repo) do
      do_install(repo, path, Keyword.get(opts, :grants, []))
    else
      {:error, :unsupported_scheme}
    end
  end

  defp do_install(repo, path, grants) do
    tmp = Path.join(System.tmp_dir!(), "shem-pack-#{System.unique_integer([:positive])}")

    try do
      with {:ok, _} <- clone(repo, tmp),
           pack_dir = Path.join(tmp, path),
           {:ok, pack} <- read_pack(pack_dir) do
        {:ok, %{removed: replaced}} = uninstall(pack["name"])
        results = Enum.map(pack["tools"], &install_tool(pack_dir, pack["name"], pack["version"], grants, &1))
        installed = for {:ok, id} <- results, do: id

        rejected =
          Enum.flat_map(results, fn
            {:error, id, reason} -> [%{id: id, reason: inspect(reason)}]
            {:needs_consent, id, requested} -> [%{id: id, reason: "needs_consent", requested: requested}]
            {:ok, _} -> []
          end)

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

  defp install_tool(pack_dir, pack_name, pack_version, grants, id) do
    with {:ok, manifest} <- read_manifest(pack_dir, id),
         :ok <- validate_contract(manifest),
         {:ok, granted} <- check_consent(manifest, grants, id),
         {:ok, source} <- read_source(pack_dir, id, manifest),
         {:ok, tool} <- gate(source, manifest, granted) do
      case tag_manifest(tool.id, pack_name, pack_version, source, granted, manifest["actions"]) do
        :ok ->
          # gate registered the pre-tag tool; rescan so lookup sees granted/actions
          Registry.rescan()
          {:ok, tool.id}

        {:error, reason} ->
          # the gate already wrote + registered this tool; a failed tag would
          # leave it on disk untagged (and thus un-uninstallable), so remove it
          remove_files(tool.id)
          Registry.rescan()
          {:error, id, reason}
      end
    else
      {:needs_consent, requested} -> {:needs_consent, id, requested}
      {:error, reason} -> {:error, id, reason}
    end
  end

  # ── Contract v2 validation ──────────────────────────────────────────────────

  defp validate_contract(m) do
    with :ok <- validate_sandbox(m["sandbox"]), do: validate_actions(m["actions"])
  end

  defp validate_sandbox(nil), do: :ok

  defp validate_sandbox(%{} = s) do
    cond do
      not is_boolean(Map.get(s, "network", false)) -> {:error, :bad_sandbox_network}
      not (is_nil(s["image"]) or is_binary(s["image"])) -> {:error, :bad_sandbox_image}
      not valid_mounts?(Map.get(s, "mounts", [])) -> {:error, :bad_sandbox_mounts}
      true -> :ok
    end
  end

  defp validate_sandbox(_), do: {:error, :bad_sandbox}

  defp valid_mounts?(mounts) when is_list(mounts) do
    Enum.all?(mounts, fn
      %{"host" => h, "container" => c} = m ->
        is_binary(h) and is_binary(c) and Map.get(m, "mode", "ro") in ["ro", "rw"]

      _ ->
        false
    end)
  end

  defp valid_mounts?(_), do: false

  defp validate_actions(nil), do: :ok

  defp validate_actions(actions) when is_list(actions) do
    valid =
      Enum.all?(actions, fn
        %{"name" => n, "risk" => r} -> is_binary(n) and r in ["read", "write", "execute"]
        _ -> false
      end)

    if valid, do: :ok, else: {:error, :bad_actions}
  end

  defp validate_actions(_), do: {:error, :bad_actions}

  # The elevation map contains ONLY what exceeds the default profile
  # (--network=none, per-language slim image, no extra mounts). %{} = default.
  defp elevation(nil), do: %{}

  defp elevation(s) do
    mounts =
      for m <- Map.get(s, "mounts", []) do
        %{"host" => m["host"], "container" => m["container"], "mode" => Map.get(m, "mode", "ro")}
      end

    %{}
    |> then(&if Map.get(s, "network", false), do: Map.put(&1, "network", true), else: &1)
    |> then(&if s["image"], do: Map.put(&1, "image", s["image"]), else: &1)
    |> then(&if mounts != [], do: Map.put(&1, "mounts", mounts), else: &1)
  end

  defp check_consent(manifest, grants, id) do
    case elevation(manifest["sandbox"]) do
      granted when granted == %{} -> {:ok, %{}}
      granted -> if id in grants, do: {:ok, granted}, else: {:needs_consent, granted}
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
    language = manifest["language"] || "elixir"
    ext = if language == "elixir", do: "ex", else: Shem.Lab.Languages.ext(language)
    case File.read(Path.join([dir, "tools", "#{id}.#{ext}"])) do
      {:ok, src} -> {:ok, src}
      _ -> {:error, :source_missing}
    end
  end

  defp gate(source, m, granted) do
    opts = [
      language: m["language"] || "elixir",
      description: m["description"] || "",
      schema: m["schema"] || %{},
      constraints: m["constraints"] || [],
      actions: m["actions"],
      sandbox: granted
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

  # Remove every on-disk file/dir for this tool: manifest, source, and the `_runtime`
  # artifact (a file for python/js, a DIRECTORY for go — hence rm_rf, not rm).
  defp remove_files(id) do
    gdir = Path.dirname(Workspace.manifest_path(id))

    case File.ls(gdir) do
      {:ok, names} ->
        names
        |> Enum.filter(&Workspace.own_file?(id, &1))
        |> Enum.each(&File.rm_rf(Path.join(gdir, &1)))

      _ ->
        :ok
    end
  end

  defp tag_manifest(tool_id, pack_name, pack_version, source, granted, actions) do
    try do
      path = Workspace.manifest_path(tool_id)
      json = File.read!(path)
      # provenance of the installed source bytes (not a verified tamper check)
      hash = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

      extra =
        %{"pack" => pack_name, "version" => pack_version, "sha256" => hash}
        |> then(&if granted != %{}, do: Map.put(&1, "granted", granted), else: &1)
        |> then(&if is_list(actions), do: Map.put(&1, "actions", actions), else: &1)

      merged = json |> Jason.decode!() |> Map.merge(extra)
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
