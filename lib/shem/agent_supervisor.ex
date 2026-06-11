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

  @spec start_agent(String.t(), Config.t()) :: {:ok, pid(), String.t()} | {:error, term()}
  def start_agent(name, %Config{} = config) do
    session_id = generate_session_id()

    case start_agent(name, config, session_id) do
      {:ok, pid} -> {:ok, pid, session_id}
      error -> error
    end
  end

  @spec start_agent(String.t(), Config.t(), String.t()) :: Horde.DynamicSupervisor.on_start_child()
  def start_agent(name, %Config{} = config, session_id) do
    via = Shem.ProcessRegistry.via_tuple(name, session_id)

    child_spec = %{
      id: name,
      start: {Shem.Agent.Server, :start_link, [{name, config, session_id, [name: via]}]},
      restart: :temporary
    }

    case Horde.DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} = result ->
        maybe_start_shadow(name, session_id, pid)
        result

      error ->
        error
    end
  end

  defp maybe_start_shadow(agent_name, session_id, agent_pid) do
    if Application.get_env(:shem, :shadow_agent_enabled, true) &&
         Process.whereis(Shem.Shadow.Supervisor) do
      shadow_spec = %{
        id: "shadow_#{agent_name}",
        start: {Shem.Shadow.Agent, :start_link, [{agent_name, session_id, agent_pid}]},
        restart: :temporary
      }

      DynamicSupervisor.start_child(Shem.Shadow.Supervisor, shadow_spec)
    end

    :ok
  end

  defp generate_session_id do
    "ses_" <> Base.encode16(:crypto.strong_rand_bytes(8))
  end
end
