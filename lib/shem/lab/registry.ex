defmodule Shem.Lab.Registry do
  use GenServer

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

  # ── Server callbacks ────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(:shem_tool_registry, [:set, :protected])
    tools = scan_graduated()
    Enum.each(tools, fn tool -> :ets.insert(table, {tool.id, tool}) end)
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

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Phase 3: reads source and builds catalogue without loading modules into VM.
  # Module loading at boot is deferred to Phase 4 when tool invocation is needed.
  defp scan_graduated do
    Workspace.list_graduated()
    |> Enum.flat_map(fn {id, path} ->
      with {:ok, source} <- File.read(path),
           {:ok, module} <- extract_module(source) do
        [%Tool{
          id: id,
          name: module |> Atom.to_string() |> String.split(".") |> List.last(),
          runtime: {:beam, module},
          source: source,
          test_source: "",
          graduated_at: DateTime.utc_now(),
          metadata: %{}
        }]
      else
        _ -> []
      end
    end)
  end

  defp extract_module(source) do
    case Regex.run(~r/defmodule\s+(\S+)\s+do/, source) do
      [_, name] -> {:ok, Module.concat([name])}
      _ -> :error
    end
  end
end
