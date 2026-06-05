defmodule Shem.Agent do
  alias Shem.{AgentSupervisor, ProcessRegistry}

  defmodule Config do
    @enforce_keys [:task, :system_prompt]
    defstruct [:task, :system_prompt, model: :default, tools: [], max_turns: 20]

    @type t :: %__MODULE__{
            task: String.t(),
            system_prompt: String.t(),
            model: atom(),
            tools: [String.t()],
            max_turns: pos_integer()
          }
  end

  @spec start(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def start(%Config{} = config) do
    name = "agent_" <> Base.encode16(:crypto.strong_rand_bytes(4))

    case AgentSupervisor.start_agent(name, config) do
      {:ok, _pid} -> {:ok, name}
      error -> error
    end
  end

  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(name) do
    case GenServer.whereis(ProcessRegistry.via_tuple(name)) do
      nil -> {:error, :not_found}
      pid -> GenServer.stop(pid)
    end
  end

  @spec status(String.t()) :: {:ok, :running | :done | :error} | {:error, :not_found}
  def status(name) do
    case GenServer.whereis(ProcessRegistry.via_tuple(name)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :status)
    end
  end

  @spec await(String.t(), timeout()) :: {:ok, :done | :error} | {:error, :not_found | :timeout}
  def await(name, timeout \\ 5_000) do
    case GenServer.whereis(ProcessRegistry.via_tuple(name)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :await, timeout)
    end
  end
end
