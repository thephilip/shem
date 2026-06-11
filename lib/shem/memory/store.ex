defmodule Shem.Memory.Store do
  use GenServer

  defp default_path, do: Path.join([System.user_home!(), ".config", "shem", "memory.dets"])

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(String.t(), String.t()) :: :ok
  def put(key, value) do
    GenServer.call(__MODULE__, {:put, key, value})
  end

  @spec get(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(key) do
    GenServer.call(__MODULE__, {:delete, key})
  end

  @spec all(String.t()) :: [{String.t(), String.t()}]
  def all(prefix \\ "") do
    GenServer.call(__MODULE__, {:all, prefix})
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
        Application.get_env(:shem, :memory_store_path, default_path())
      )

    path_charlist = to_charlist(path)
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(path_charlist, type: :set, file: path_charlist) do
      {:ok, table} -> {:ok, %{table: table}}
      {:error, reason} -> {:stop, {:dets_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    :ok = :dets.insert(state.table, {key, value, DateTime.utc_now()})
    {:reply, :ok, state}
  end

  def handle_call({:get, key}, _from, state) do
    result =
      case :dets.lookup(state.table, key) do
        [{^key, value, _written_at}] -> {:ok, value}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call({:delete, key}, _from, state) do
    result =
      case :dets.lookup(state.table, key) do
        [{^key, _value, _written_at}] ->
          :dets.delete(state.table, key)
          :ok

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call({:all, prefix}, _from, state) do
    entries =
      :dets.foldl(
        fn {k, v, _written_at}, acc ->
          if String.starts_with?(k, prefix), do: [{k, v} | acc], else: acc
        end,
        [],
        state.table
      )
      |> Enum.sort_by(&elem(&1, 0))

    {:reply, entries, state}
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
