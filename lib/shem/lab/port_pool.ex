defmodule Shem.Lab.PortPool do
  use GenServer
  require Logger

  @default_timeout 30_000

  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)
    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec call(atom() | pid(), map(), timeout()) :: {:ok, any()} | {:error, String.t()}
  def call(pool, args, timeout \\ @default_timeout) do
    meta = %{node: node()}

    :telemetry.span([:shem, :port_pool, :roundtrip], meta, fn ->
      {GenServer.call(pool, {:call, args}, timeout), meta}
    end)
  end

  # ── Server ────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    tool_id      = Keyword.fetch!(opts, :tool_id)
    runtime_path = Keyword.fetch!(opts, :runtime_path)
    pool_size    = Keyword.get(opts, :pool_size, 2)
    language     = Keyword.get(opts, :language, "python")
    executable   = Keyword.get(opts, :executable, Shem.Lab.Languages.exe(language))

    maybe_warn_unsandboxed(tool_id, language)

    workers = for _ <- 1..pool_size, do: open_port(runtime_path, executable, language, tool_id)

    {:ok, %{
      tool_id: tool_id,
      runtime_path: runtime_path,
      executable: executable,
      language: language,
      idle: workers,
      busy: %{},
      queue: :queue.new()
    }}
  end

  defp maybe_warn_unsandboxed(tool_id, language) do
    if is_nil(Application.get_env(:shem, :container_runtime_bin)) and
         Application.get_env(:shem, :executor_backend) != :local do
      Logger.warning(
        "PortPool: no container runtime — tool #{tool_id} (#{language}) runs UNSANDBOXED on host"
      )
    end
  end

  @impl true
  def handle_call({:call, args}, from, state) do
    case state.idle do
      [port | rest] ->
        send_to_port(port, args)
        busy = Map.put(state.busy, port, from)
        {:noreply, %{state | idle: rest, busy: busy}}

      [] ->
        queue = :queue.in({args, from}, state.queue)
        {:noreply, %{state | queue: queue}}
    end
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, state) when is_port(port) do
    line = String.trim(line)

    case Map.pop(state.busy, port) do
      {nil, _} ->
        {:noreply, state}

      {from, busy} ->
        result =
          case Jason.decode(line) do
            {:ok, %{"__error__" => reason}} -> {:error, reason}
            {:ok, value} -> {:ok, value}
            {:error, _}  -> {:error, "invalid JSON from port: #{line}"}
          end

        GenServer.reply(from, result)

        {new_state, idle} = maybe_dequeue(%{state | busy: busy}, port)
        {:noreply, %{new_state | idle: idle}}
    end
  end

  def handle_info({port, {:exit_status, code}}, state) when is_port(port) do
    Logger.warning("PortPool: worker exited with code #{code}, restarting")
    new_port = open_port(state.runtime_path, state.executable, state.language, state.tool_id)

    {new_state, idle} =
      case Map.pop(state.busy, port) do
        {nil, _} ->
          {state, [new_port | state.idle]}

        {from, busy} ->
          GenServer.reply(from, {:error, "worker crashed (exit #{code})"})
          {%{state | busy: busy}, [new_port | state.idle]}
      end

    {:noreply, %{new_state | idle: idle}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp open_port(runtime_path, host_exe, language, tool_id) do
    runtime_bin = Application.get_env(:shem, :container_runtime_bin)

    {exe, args, port_opts} =
      Shem.Lab.Sandbox.spawn_spec(runtime_bin, %{
        runtime_path: runtime_path,
        language: language,
        tool_id: tool_id,
        host_exe: host_exe
      })

    case System.find_executable(exe) do
      nil ->
        raise "PortPool: executable not found on PATH: #{exe}"

      path ->
        base = [:binary, :use_stdio, :line, :exit_status, {:args, args}]
        Port.open({:spawn_executable, path}, base ++ port_opts)
    end
  end

  defp send_to_port(port, args) do
    Port.command(port, Jason.encode!(args) <> "\n")
  end

  defp maybe_dequeue(state, idle_port) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        {state, [idle_port | state.idle]}

      {{:value, {args, from}}, queue} ->
        send_to_port(idle_port, args)
        busy = Map.put(state.busy, idle_port, from)
        {%{state | busy: busy, queue: queue}, state.idle}
    end
  end
end
