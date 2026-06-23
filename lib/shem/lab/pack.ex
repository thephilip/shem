defmodule Shem.Lab.Pack do
  @moduledoc """
  Install/uninstall git-distributed tool packs. Every tool is re-verified
  through the local graduation gate before it is trusted — installing a pack
  runs third-party code through the same gate that agent-authored tools pass.
  """
  alias Shem.Lab.{GraduationGate, Workspace}

  @spec install(String.t(), String.t()) ::
          {:ok, %{name: String.t(), installed: [String.t()], rejected: [map()]}}
          | {:error, term()}
  def install(repo, path \\ ".") do
    tmp = Path.join(System.tmp_dir!(), "shem-pack-#{System.unique_integer([:positive])}")

    try do
      with {:ok, _} <- clone(repo, tmp),
           pack_dir = Path.join(tmp, path),
           {:ok, pack} <- read_pack(pack_dir) do
        results = Enum.map(pack["tools"], &install_tool(pack_dir, pack["name"], &1))
        installed = for {:ok, id} <- results, do: id
        rejected = for {:error, id, reason} <- results, do: %{id: id, reason: inspect(reason)}
        {:ok, %{name: pack["name"], installed: installed, rejected: rejected}}
      end
    after
      File.rm_rf(tmp)
    end
  end

  defp clone(repo, tmp) do
    case System.cmd("git", ["clone", "--depth", "1", repo, tmp], stderr_to_stdout: true) do
      {_, 0} -> {:ok, tmp}
      {out, _} -> {:error, {:clone_failed, String.trim(out)}}
    end
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

  defp install_tool(pack_dir, pack_name, id) do
    with {:ok, manifest} <- read_manifest(pack_dir, id),
         {:ok, source} <- read_source(pack_dir, id, manifest),
         {:ok, tool} <- gate(source, manifest) do
      tag_manifest(tool.id, pack_name, source)
      {:ok, tool.id}
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
  defp tag_manifest(tool_id, pack_name, source) do
    path = Workspace.manifest_path(tool_id)
    json = File.read!(path)
    hash = :crypto.hash(:sha256, source <> json) |> Base.encode16(case: :lower)

    merged =
      json
      |> Jason.decode!()
      |> Map.merge(%{"pack" => pack_name, "sha256" => hash})

    File.write!(path, Jason.encode!(merged, pretty: true))
  end
end
