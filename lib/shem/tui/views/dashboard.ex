defmodule Shem.TUI.Views.Dashboard do
  import Ratatouille.View
  import Ratatouille.Constants, only: [color: 1, attribute: 1]

  def render(model) do
    view do
      row do
        column(size: 8) do
          panel(title: "Shem // Dashboard", color: color(:green)) do
            label(content: "Agents: 0 active", color: color(:white))
            label(content: "")
            label(content: "CPU: --   MEM: --   GPU: --", color: color(:cyan))
            label(content: "")

            label(
              content: "Token spend: $0.0000 session / $0.0000 lifetime",
              color: color(:yellow)
            )
          end
        end

        column(size: 4) do
          panel(title: "Lab Status", color: color(:magenta)) do
            label(content: "Tools graduated: #{model.tool_count}", color: color(:white))

            label(
              content:
                "MCP: localhost:#{Application.get_env(:shem, :mcp_port, 4000)} — #{model.mcp_client_count} connected",
              color: color(:cyan)
            )

            label(
              content:
                "Sessions: #{model.event_log_stats.sessions}   Events: #{model.event_log_stats.total_events}",
              color: color(:white)
            )

            label(content: "")

            label(
              content: "Lab: idle",
              attributes: [attribute(:bold)],
              color: color(:magenta)
            )
          end
        end
      end

      row do
        column(size: 12) do
          panel(title: status_bar_title(model), color: status_bar_color(model)) do
            label(
              content: status_bar_content(model),
              attributes: [attribute(:bold)],
              color: color(:white)
            )
          end
        end
      end
    end
  end

  defp status_bar_title(%{paused: true}),
    do: "[ PAUSED — press SPACE to resume ]"

  defp status_bar_title(%{command_buffer: "/" <> _ = buf}),
    do: "Command: #{buf}"

  defp status_bar_title(_),
    do: "Ready  |  d=Dashboard  i=Interactive  /=Command  SPACE=Pause  q=Quit"

  defp status_bar_color(%{paused: true}), do: color(:red)
  defp status_bar_color(_), do: color(:green)

  defp status_bar_content(%{paused: true}),
    do: "Agent loop suspended. Type a prompt to steer, then SPACE to resume."

  defp status_bar_content(%{command_buffer: ""}), do: "Shem is watching."
  defp status_bar_content(%{command_buffer: buf}), do: buf
end
