defmodule Shem.LLM.BudgetServer do
  use GenServer

  # ── Client API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    limit = Keyword.get(opts, :limit, Application.get_env(:shem, :llm_budget_limit, 500_000))
    threshold = Keyword.get(opts, :soft_threshold, Application.get_env(:shem, :llm_soft_threshold, 0.8))
    GenServer.start_link(__MODULE__, {limit, threshold}, name: name)
  end

  @spec check(GenServer.server()) :: :ok | {:error, :budget_exhausted}
  def check(server \\ __MODULE__), do: GenServer.call(server, :check)

  @spec deduct(GenServer.server(), non_neg_integer()) :: :ok
  def deduct(server \\ __MODULE__, tokens), do: GenServer.call(server, {:deduct, tokens})

  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # ── Server callbacks ────────────────────────────────────────────────────────

  @impl true
  def init({limit, threshold}) do
    {:ok, %{global_limit: limit, soft_threshold: threshold, tokens_used: 0, soft_warned?: false}}
  end

  @impl true
  def handle_call(:check, _from, state) do
    if state.tokens_used >= state.global_limit do
      {:reply, {:error, :budget_exhausted}, state}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:deduct, tokens}, _from, state) do
    new_used = state.tokens_used + tokens
    soft_limit = state.global_limit * state.soft_threshold

    new_warned = state.soft_warned? or new_used >= soft_limit

    {:reply, :ok, %{state | tokens_used: new_used, soft_warned?: new_warned}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | tokens_used: 0, soft_warned?: false}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end
end
