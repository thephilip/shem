defmodule Shem.AgentSupervisor do
  use DynamicSupervisor

  alias Shem.Agent.Config

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_agent(String.t(), Config.t()) :: DynamicSupervisor.on_start_child()
  def start_agent(name, %Config{} = config) do
    via = Shem.ProcessRegistry.via_tuple(name)

    child_spec = %{
      id: name,
      start: {Shem.Agent.Server, :start_link, [{name, config, [name: via]}]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
end
