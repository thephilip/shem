defmodule Shem.AgentSupervisor do
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_agent(term(), (-> any())) :: DynamicSupervisor.on_start_child()
  def start_agent(name, init_fn) do
    via = Shem.ProcessRegistry.via_tuple(name)

    child_spec = %{
      id: name,
      start: {Agent, :start_link, [init_fn, [name: via]]},
      restart: :permanent
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
end
