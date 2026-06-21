defmodule Shem.TUI.Views.Dashboard do
  import Ratatouille.View
  import Ratatouille.Constants, only: [color: 1, attribute: 1]

  def render(model) do
    view do
      row do
        column(size: 8) do
          panel(title: "Shem // Dashboard", color: color(:green)) do
            label(content: agents_line(model.agents), color: color(:white))
            label(content: "")
            label(content: Shem.TUI.SystemStats.format(model.system_stats), color: color(:cyan))
            label(content: "")

            label(
              content: "Tokens: #{model.budget.tokens_used} / #{model.budget.global_limit} session",
              color: color(:yellow)
            )

            label(content: "")
            label(content: "Latency (p50/p99 ms)", attributes: [attribute(:bold)], color: color(:cyan))

            for line <- telemetry_lines(Map.get(model, :telemetry_stats, %{})) do
              label(content: line, color: color(:white))
            end
          end
        end

        column(size: 4) do
          panel(title: "Lab Status", color: color(:magenta)) do
            label(content: "Tools graduated: #{model.tool_count}", color: color(:white))

            label(
              content:
                "MCP: #{Application.get_env(:shem, :mcp_host, "127.0.0.1")}:#{Application.get_env(:shem, :mcp_port, 4000)} — #{model.mcp_client_count} connected",
              color: color(:cyan)
            )

            label(
              content: "MCP clients: #{model.mcp_outbound_count} connected",
              color: color(:cyan)
            )

            label(
              content: "Cluster (#{length(Map.get(model, :cluster_nodes, []))} nodes)",
              attributes: [attribute(:bold)],
              color: color(:cyan)
            )

            for %{node: n, agents: count, status: _status} <- Map.get(model, :cluster_nodes, []) do
              marker = if n == Node.self(), do: "◈", else: "◇"

              label(
                content: "  #{marker} #{n}  #{count} agents",
                color: if(n == Node.self(), do: color(:cyan), else: color(:white))
              )
            end

            label(content: "")

            label(
              content:
                "Sessions: #{model.event_log_stats.sessions}   Events: #{model.event_log_stats.total_events}",
              color: color(:white)
            )

            label(content: "")

            label(
              content: trust_summary(model.trust_counts),
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

  defp trust_summary(%{high: h, medium: m, low: l, unrated: u}) do
    "Trust: #{h} high  #{m} med  #{l} low  #{u} unrated"
  end

  defp trust_summary(_), do: "Trust: —"

  @telemetry_labels %{
    [:shem, :agent, :turn, :stop] => "agent turn",
    [:shem, :llm, :call, :stop] => "llm call",
    [:shem, :event_log, :append, :stop] => "evlog append",
    [:shem, :port_pool, :roundtrip, :stop] => "port rtt"
  }

  defp telemetry_lines(stats) when map_size(stats) == 0, do: ["  (no events yet)"]

  defp telemetry_lines(stats) do
    lines =
      for {{event, group}, s} <- Enum.sort(stats), label = @telemetry_labels[event] do
        name = if group, do: "#{label}:#{group}", else: label
        "  #{String.pad_trailing(name, 18)} #{fmt(s.p50_ms)}/#{fmt(s.p99_ms)}  (#{s.count})"
      end

    if lines == [], do: ["  (no events yet)"], else: lines
  end

  defp fmt(ms), do: :erlang.float_to_binary(ms * 1.0, decimals: 1)

  defp agents_line(agents) do
    running = Enum.count(agents, &(&1.status == :running))
    "Agents: #{length(agents)} active (#{running} running)"
  end
end
