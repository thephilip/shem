defmodule Shem.Lab.PortPool.Supervisor do
  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec ensure_started(String.t(), String.t(), String.t()) :: {:ok, pid()} | {:error, any()}
  def ensure_started(tool_id, runtime_path, language \\ "python") do
    # Pool name includes language so a tool re-registered under a different runtime
    # (e.g. a tool-pack replace that swaps Python for JS) gets a fresh pool with the
    # right interpreter, instead of silently reusing the stale one.
    pool_name = pool_name(tool_id, language)
    pool_size = Application.get_env(:shem, :port_pool_size, 2)

    case DynamicSupervisor.start_child(__MODULE__,
      {Shem.Lab.PortPool,
       [tool_id: tool_id, runtime_path: runtime_path, language: language,
        pool_size: pool_size, name: pool_name]}
    ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  def pool_name(tool_id, language \\ "python"), do: :"shem_port_pool_#{tool_id}_#{language}"
end
