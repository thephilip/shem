defmodule Shem.Agent do
  alias Shem.{AgentSupervisor, ProcessRegistry}

  defmodule Config do
    @enforce_keys [:task, :system_prompt]
    defstruct [:task, :system_prompt, model: :default, tools: [], max_turns: 20,
               spawn_depth: 0, conversational: false, project_context: nil, fence: nil,
               placement: :any]

    @type placement ::
            :any
            | {:node, node()}
            | {:labels, %{String.t() => String.t()}}
            | {:labels, %{String.t() => String.t()}, :required}

    @type t :: %__MODULE__{
            task: String.t(),
            system_prompt: String.t(),
            model: atom(),
            tools: [String.t()],
            max_turns: pos_integer(),
            spawn_depth: non_neg_integer(),
            project_context: Shem.Context.Project.t() | nil,
            conversational: boolean(),
            fence: String.t() | nil,
            placement: placement()
          }
  end

  @spec start(Config.t()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def start(%Config{} = config) do
    name = "agent_" <> Base.encode16(:crypto.strong_rand_bytes(4))

    case AgentSupervisor.start_agent(name, config) do
      {:ok, _pid, session_id} -> {:ok, name, session_id}
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

  @spec status(String.t()) :: {:ok, :running | :done | :error | :waiting} | {:error, :not_found}
  def status(name) do
    case GenServer.whereis(ProcessRegistry.via_tuple(name)) do
      nil ->
        {:error, :not_found}

      pid ->
        try do
          GenServer.call(pid, :status)
        catch
          :exit, _ -> {:error, :not_found}
        end
    end
  end

  @spec await(String.t(), timeout()) ::
          {:ok, :done | :error | :waiting} | {:error, :not_found | :timeout}
  def await(name, timeout \\ 5_000) do
    case GenServer.whereis(ProcessRegistry.via_tuple(name)) do
      nil -> {:error, :not_found}
      pid ->
        try do
          GenServer.call(pid, :await, timeout)
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
        end
    end
  end

  @spec send_message(String.t(), String.t()) ::
          :ok | {:error, :not_found | :not_waiting | :timeout}
  def send_message(name, message) do
    case GenServer.whereis(ProcessRegistry.via_tuple(name)) do
      nil ->
        {:error, :not_found}

      pid ->
        try do
          GenServer.call(pid, {:message, message})
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
        end
    end
  end

  @spec session_id(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def session_id(name) do
    case ProcessRegistry.lookup(name) do
      {_pid, session_id} -> {:ok, session_id}
      nil -> {:error, :not_found}
    end
  end

  @spec set_fence(String.t(), String.t() | nil) :: :ok | {:error, :not_found}
  def set_fence(name, path) do
    case GenServer.whereis(ProcessRegistry.via_tuple(name)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:set_fence, path})
    end
  end

  @spec pause(String.t()) :: :ok | {:error, :not_found | :not_running}
  def pause(name), do: agent_call(name, :pause)

  @spec steer(String.t(), String.t()) :: :ok | {:error, :not_found | :not_paused}
  def steer(name, text), do: agent_call(name, {:steer, text})

  @spec unpause(String.t()) :: :ok | {:error, :not_found | :not_paused}
  def unpause(name), do: agent_call(name, :unpause)

  defp agent_call(name, msg) do
    case GenServer.whereis(ProcessRegistry.via_tuple(name)) do
      nil ->
        {:error, :not_found}

      pid ->
        try do
          GenServer.call(pid, msg)
        catch
          :exit, _ -> {:error, :not_found}
        end
    end
  end

  @spec start_with_preset(String.t(), String.t(), keyword()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def start_with_preset(preset_name, task, opts \\ []) do
    with {:ok, preset} <- Shem.Agent.Preset.resolve(preset_name) do
      config = %Config{
        task: task,
        system_prompt: preset.system_prompt,
        # tools: [] means allow-all in Config; :all is preset-only shorthand
        tools: if(preset.tools == :all, do: [], else: preset.tools),
        max_turns: preset.max_turns,
        spawn_depth: Keyword.get(opts, :spawn_depth, 0),
        conversational: Keyword.get(opts, :conversational, false),
        project_context: Keyword.get(opts, :project_context, Shem.Context.Project.detect()),
        placement: Keyword.get(opts, :placement, :any)
      }
      start(config)
    end
  end

  @spec await_result(String.t(), timeout()) :: {:ok, String.t()} | {:error, term()}
  def await_result(name, timeout \\ 300_000) do
    with {:ok, sid} <- session_id(name),
         {:ok, :done} <- await(name, timeout),
         {:ok, events} <- Shem.EventLog.events(sid),
         %{payload: payload} <-
           Enum.find(Enum.reverse(events), &(&1.type == :agent_done)) do
      case payload do
        %{reason: :answer, content: content} -> {:ok, content}
        %{reason: reason} -> {:error, {:agent_stopped, reason}}
      end
    else
      {:ok, :error} -> {:error, :sub_agent_failed}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :no_result}
    end
  end

  @spec resume(String.t(), String.t()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def resume(session_id, task) do
    with {:ok, preset} <- Shem.Agent.Preset.resolve("general") do
      config = %Config{
        task: task,
        system_prompt: preset.system_prompt,
        tools: [],
        max_turns: 20
      }

      name = "agent_" <> Base.encode16(:crypto.strong_rand_bytes(4))

      case AgentSupervisor.start_agent(name, config, session_id) do
        {:ok, _pid} -> {:ok, name, session_id}
        error -> error
      end
    end
  end
end
