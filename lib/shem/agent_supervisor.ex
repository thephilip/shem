defmodule Shem.AgentSupervisor do
  use Horde.DynamicSupervisor

  alias Shem.Agent.Config

  def start_link(init_arg) do
    Horde.DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    Horde.DynamicSupervisor.init(strategy: :one_for_one, members: :auto)
  end

  @spec start_agent(String.t(), Config.t()) :: Horde.DynamicSupervisor.on_start_child()
  def start_agent(name, %Config{} = config) do
    session_id = generate_session_id()
    via = Shem.ProcessRegistry.via_tuple(name)

    child_spec = %{
      id: name,
      start: {Shem.Agent.Server, :start_link, [{name, config, session_id, [name: via]}]},
      restart: :temporary
    }

    Horde.DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  defp generate_session_id do
    "ses_" <> Base.encode16(:crypto.strong_rand_bytes(8))
  end
end
