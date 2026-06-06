defmodule Shem.Agent.PresetStore do
  use GenServer

  @default_path Path.join([System.user_home!(), ".config", "shem", "preset_store.dets"])

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(String.t(), map()) :: :ok
  def put(name, preset) do
    GenServer.call(__MODULE__, {:put, name, preset})
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(name) do
    GenServer.call(__MODULE__, {:delete, name})
  end

  @spec all() :: %{String.t() => map()}
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl true
  def init(opts) do
    path =
      Keyword.get(
        opts,
        :path,
        Application.get_env(:shem, :preset_store_path, @default_path)
      )

    path_charlist = to_charlist(path)
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(path_charlist, type: :set, file: path_charlist) do
      {:ok, table} -> {:ok, %{table: table}}
      {:error, reason} -> {:stop, {:dets_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:put, name, preset}, _from, state) do
    entry = Map.put(preset, :name, name)
    :ok = :dets.insert(state.table, {name, entry})
    {:reply, :ok, state}
  end

  def handle_call({:get, name}, _from, state) do
    result =
      case :dets.lookup(state.table, name) do
        [{^name, entry}] -> {:ok, entry}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call({:delete, name}, _from, state) do
    result =
      case :dets.lookup(state.table, name) do
        [{^name, _}] ->
          :dets.delete(state.table, name)
          :ok

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call(:all, _from, state) do
    result =
      :dets.foldl(
        fn {name, entry}, acc -> Map.put(acc, name, entry) end,
        %{},
        state.table
      )

    {:reply, result, state}
  end

  def handle_call(:flush, _from, state) do
    :dets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    :dets.close(state.table)
  end
end
