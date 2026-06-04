defmodule Shem.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Shem.Registry},
        Shem.AgentSupervisor,
        Shem.EventLog,
        {Task.Supervisor, name: Shem.Lab.TaskSupervisor},
        Shem.Lab.Registry
      ] ++ mcp_children() ++ tui_children()

    opts = [strategy: :one_for_one, name: Shem.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp mcp_children do
    if Application.get_env(:shem, :start_mcp, true) do
      [Shem.MCP.Server]
    else
      []
    end
  end

  defp tui_children do
    if Application.get_env(:shem, :start_tui, true) do
      [Shem.TUI.RuntimeSupervisor]
    else
      []
    end
  end
end
