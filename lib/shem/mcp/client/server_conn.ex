defmodule Shem.MCP.Client.ServerConn do
  use GenServer

  alias Shem.MCP.Client.Protocol
  require Logger

  @handshake_init_id 0
  @handshake_tools_id 1

  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    registry = Keyword.get(opts, :registry, Shem.Registry)
    via = {:via, Registry, {registry, {__MODULE__, config.name}}}
    GenServer.start_link(__MODULE__, opts, name: via)
  end

  def child_spec(opts) do
    config = Keyword.fetch!(opts, :config)
    %{
      id: {__MODULE__, config.name},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)

    port_opener =
      Keyword.get(opts, :port_opener, &default_port_opener/2)

    port_writer =
      Keyword.get(opts, :port_writer, &default_port_writer/2)

    port = port_opener.(config.cmd, config.args)

    state = %{
      config: config,
      port: port,
      port_writer: port_writer,
      status: :connecting,
      handshake_step: :awaiting_init,
      next_id: 2,
      pending: %{},
      tools: []
    }

    send_to_port(state, Protocol.encode_request(@handshake_init_id, "initialize", %{
      "protocolVersion" => "2024-11-05",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "shem", "version" => "0.1.0"}
    }))

    {:ok, state}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    {:reply, {:ok, state.tools}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Protocol.decode_message(line) do
      {:ok, msg} -> handle_message(msg, state)
      {:error, reason} ->
        Logger.warning("ServerConn #{state.config.name}: malformed line (#{reason}), skipping")
        {:noreply, state}
    end
  end

  def handle_info({port, {:data, {:noeol, _}}}, %{port: port} = state) do
    Logger.warning("ServerConn #{state.config.name}: oversized line from server, skipping")
    {:noreply, state}
  end

  # --- private ---

  defp handle_message(%{"id" => @handshake_init_id, "result" => _}, %{handshake_step: :awaiting_init} = state) do
    send_to_port(state, Protocol.encode_notification("notifications/initialized", %{}))
    send_to_port(state, Protocol.encode_request(@handshake_tools_id, "tools/list", %{}))
    {:noreply, %{state | handshake_step: :awaiting_tools}}
  end

  defp handle_message(%{"id" => @handshake_tools_id, "result" => %{"tools" => tools}}, %{handshake_step: :awaiting_tools} = state) do
    {:noreply, %{state | status: :ready, handshake_step: nil, tools: tools}}
  end

  defp handle_message(_msg, state) do
    {:noreply, state}
  end

  defp send_to_port(state, data), do: state.port_writer.(state.port, data)

  defp default_port_opener(cmd, args) do
    executable = System.find_executable(cmd) || raise "mcp client command not found: #{cmd}"
    Port.open({:spawn_executable, executable}, [
      :binary,
      :exit_status,
      {:line, 65_536},
      :use_stdio,
      {:args, args}
    ])
  end

  defp default_port_writer(port, data), do: Port.command(port, data)
end
