defmodule Shem.Trust.Store do
  use GenServer

  @default_path Path.join([System.user_home!(), ".config", "shem", "trust.dets"])
  @recency_weight 0.7

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record(String.t(), %{outcome: atom(), rounds: non_neg_integer()}) :: :ok
  def record(tool_id, %{outcome: outcome, rounds: rounds}) do
    GenServer.call(__MODULE__, {:record, tool_id, outcome, rounds})
  end

  @spec score(String.t()) :: {:ok, float()} | {:error, :unrated}
  def score(tool_id) do
    GenServer.call(__MODULE__, {:score, tool_id})
  end

  @spec all() :: %{String.t() => float()}
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
        Application.get_env(:shem, :trust_store_path, @default_path)
      )

    path_charlist = to_charlist(path)
    File.mkdir_p!(Path.dirname(path))
    case :dets.open_file(path_charlist, type: :set, file: path_charlist) do
      {:ok, table} -> {:ok, %{table: table}}
      {:error, reason} -> {:stop, {:dets_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:record, tool_id, outcome, rounds}, _from, state) do
    prior =
      case :dets.lookup(state.table, tool_id) do
        [{^tool_id, entry}] -> entry
        [] -> nil
      end

    outcome_score = compute_outcome_score(outcome, rounds)
    new_score = blend(prior && prior.score, outcome_score)

    entry = %{
      tool_id: tool_id,
      score: new_score,
      last_updated: DateTime.utc_now(),
      hardening_count: if(prior, do: prior.hardening_count + 1, else: 1)
    }

    :ok = :dets.insert(state.table, {tool_id, entry})
    {:reply, :ok, state}
  end

  def handle_call({:score, tool_id}, _from, state) do
    result =
      case :dets.lookup(state.table, tool_id) do
        [{^tool_id, entry}] -> {:ok, entry.score}
        [] -> {:error, :unrated}
      end

    {:reply, result, state}
  end

  def handle_call(:all, _from, state) do
    result =
      :dets.foldl(
        fn {id, entry}, acc -> Map.put(acc, id, entry.score) end,
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

  defp compute_outcome_score(:clean, 1), do: 1.0
  defp compute_outcome_score(:clean, n), do: max(1.0 - (n - 1) * 0.15, 0.3)
  defp compute_outcome_score(:max_rounds_reached, _), do: 0.2
  defp compute_outcome_score(:error, _), do: 0.1
  defp compute_outcome_score(_outcome, _rounds), do: 0.0

  defp blend(nil, outcome_score), do: outcome_score

  defp blend(prior, outcome_score) do
    (@recency_weight * outcome_score + (1 - @recency_weight) * prior)
    |> max(0.0)
    |> min(1.0)
  end
end
