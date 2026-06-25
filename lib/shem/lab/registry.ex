defmodule Shem.Lab.Registry do
  use GenServer
  require Logger

  alias Shem.Lab.Workspace
  alias Shem.Tool

  # ── Client API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec lookup(String.t()) :: {:ok, Tool.t()} | {:error, :not_found}
  def lookup(id), do: GenServer.call(__MODULE__, {:lookup, id})

  @spec lookup_by_name(String.t()) :: {:ok, Tool.t()} | {:error, :not_found}
  def lookup_by_name(name), do: GenServer.call(__MODULE__, {:lookup_by_name, name})

  @spec all() :: [Tool.t()]
  def all, do: GenServer.call(__MODULE__, :all)

  @spec register(Tool.t()) :: :ok
  def register(%Tool{} = tool), do: GenServer.call(__MODULE__, {:register, tool})

  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush)

  @spec rescan() :: :ok
  @doc "Rebuild the registry table from disk: seeds + every graduated manifest."
  def rescan, do: GenServer.call(__MODULE__, :rescan)

  # ── Server callbacks ────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(:shem_tool_registry, [:set, :protected])
    # Seed modules are compiled into the release but lazy-loaded; force-load so
    # dispatch's ensure_loaded/1 (:code.is_loaded) is a true no-op, not a recompile.
    Enum.each(Shem.SeedTools.modules(), &Code.ensure_loaded!/1)
    Enum.each(load_all(), fn tool -> :ets.insert(table, {tool.id, tool}) end)
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:lookup, id}, _from, state) do
    result =
      case :ets.lookup(state.table, id) do
        [{^id, tool}] -> {:ok, tool}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:lookup_by_name, name}, _from, state) do
    result =
      state.table
      |> :ets.tab2list()
      |> Enum.find(fn {_id, tool} -> tool.name == name end)
      |> case do
        {_id, tool} -> {:ok, tool}
        nil -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:all, _from, state) do
    tools = state.table |> :ets.tab2list() |> Enum.map(fn {_id, tool} -> tool end)
    {:reply, tools, state}
  end

  @impl true
  def handle_call({:register, tool}, _from, state) do
    :ets.insert(state.table, {tool.id, tool})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:rescan, _from, state) do
    :ets.delete_all_objects(state.table)
    Enum.each(load_all(), fn tool -> :ets.insert(state.table, {tool.id, tool}) end)
    {:reply, :ok, state}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Seeds first, graduated last: a user-graduated tool overrides a seed on id collision.
  defp load_all, do: Shem.SeedTools.all() ++ scan_graduated()

  defp scan_graduated do
    Workspace.list_graduated()
    |> Enum.flat_map(fn
      {id, manifest_path} ->
        with {:ok, json} <- File.read(manifest_path),
             {:ok, m} <- Jason.decode(json) do
          # a single broken graduated tool must not crash boot — quarantine it
          # (move aside) so it loads no further AND stops re-warning every boot
          try do
            [build_tool_from_manifest(id, m)]
          rescue
            e ->
              quarantine(id, manifest_path)
              Logger.warning("quarantined unloadable graduated tool #{id} -> .broken/: #{Exception.message(e)}")
              []
          end
        else
          _ -> []
        end

      {:legacy, id, source_path} ->
        # A manifestless broken tool takes THIS branch, not the rescue above, so
        # quarantine here too — but only when the source is present yet unloadable
        # (extract_module :error). A transiently-missing file (File.read error)
        # has nothing to move; leave it.
        case File.read(source_path) do
          {:ok, source} ->
            case extract_module(source) do
              {:ok, module} ->
                [%Tool{
                  id: id,
                  name: module |> Atom.to_string() |> String.split(".") |> List.last(),
                  runtime: {:beam, module},
                  source: source,
                  test_source: "",
                  graduated_at: DateTime.utc_now(),
                  metadata: %{}
                }]

              :error ->
                quarantine(id, source_path)
                Logger.warning("quarantined unloadable legacy graduated tool #{id} -> .broken/")
                []
            end

          _ ->
            []
        end
    end)
  end

  # Move a broken tool's files into graduated/.broken/ so the boot scan stops
  # re-warning on every start and the source is preserved for inspection (not
  # deleted). Best-effort: File.* here are non-bang, so this never crashes the scan.
  # .broken/ is a subdir, so list_graduated/0 (top-level ls) never re-scans it.
  defp quarantine(id, manifest_path) do
    dir = Path.join(Path.dirname(manifest_path), ".broken")
    File.mkdir_p(dir)
    base = Path.rootname(manifest_path)

    Enum.each([".json", ".ex", ".py", "_runtime.py"], fn suffix ->
      src = base <> suffix
      if File.exists?(src), do: File.rename(src, Path.join(dir, "#{id}#{suffix}"))
    end)
  end

  defp build_tool_from_manifest(id, %{"language" => "elixir"} = m) do
    source_path = Workspace.graduated_path(id)
    source = case File.read(source_path) do
      {:ok, s} -> s
      _ -> ""
    end
    {:ok, module} = extract_module(source)

    %Tool{
      id: id,
      name: m["name"] || (module |> Atom.to_string() |> String.split(".") |> List.last()),
      runtime: {:beam, module},
      source: source,
      test_source: m["test_source"] || "",
      constraints: m["constraints"] || [],
      graduated_at: parse_dt(m["graduated_at"]),
      metadata: %{
        "description" => m["description"] || "",
        "schema"      => m["schema"] || %{}
      }
    }
  end

  defp build_tool_from_manifest(id, %{"runtime_path" => runtime_path} = m) do
    source_path = Path.join(Path.dirname(runtime_path), "#{id}.py")
    source = case File.read(source_path) do
      {:ok, s} -> s
      _ -> ""
    end

    %Tool{
      id: id,
      name: m["name"] || id,
      runtime: {:port, runtime_path},
      source: source,
      test_source: m["test_source"] || "",
      constraints: m["constraints"] || [],
      graduated_at: parse_dt(m["graduated_at"]),
      metadata: %{
        "language"    => m["language"] || "python",
        "description" => m["description"] || "",
        "schema"      => m["schema"] || %{}
      }
    }
  end

  defp parse_dt(nil), do: DateTime.utc_now()
  defp parse_dt(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp extract_module(source) do
    case Regex.run(~r/defmodule\s+(\S+)\s+do/, source) do
      [_, name] -> {:ok, Module.concat([name])}
      _ -> :error
    end
  end
end
