defmodule Shem.TUI.Views.Interactive do
  import Ratatouille.View
  import Ratatouille.Constants, only: [color: 1, attribute: 1]

  def render(%{mode: :multiline_input} = model) do
    name =
      case model.multiline_target do
        {:preset_add, n} -> n
        _ -> "input"
      end

    view do
      row do
        column(size: 8) do
          panel(title: "Shem // New Preset · #{name}", color: color(:cyan)) do
            label(
              content: "Type lines. Enter '/done' to save, Esc to cancel.",
              color: color(:yellow)
            )

            label(content: "")

            for line <- model.multiline_buffer do
              label(content: line, color: color(:white))
            end

            label(content: "▸ #{model.command_buffer}_", color: color(:cyan))
          end
        end

        column(size: 4) do
          render_event_log(model)
        end
      end

    end
  end

  def render(model) do
    rows =
      [content_row(model)] ++
        autocomplete_rows(model) ++
        [prompt_row(model)]

    view(rows)
  end

  defp content_row(model) do
    row do
      column(size: 3) do
        render_agent_list(model)
      end

      column(size: 6) do
        render_turn_card(model)
      end

      column(size: 3) do
        render_event_log(model)
      end
    end
  end

  defp autocomplete_rows(%{command_buffer: "/" <> _} = model) do
    suggestions =
      Shem.TUI.Autocomplete.suggest(model.command_buffer, Shem.TUI.CommandDispatch.commands())
      |> Enum.take(6)

    if suggestions == [] do
      []
    else
      [
        row do
          column(size: 12) do
            panel(title: "Commands · ↑↓ select · Tab complete", color: color(:cyan)) do
              for {{cmd, desc}, i} <- Enum.with_index(suggestions) do
                marker = if i == model.ac_index, do: "▸", else: " "

                label(
                  content: "#{marker} #{String.pad_trailing(cmd, 28)} #{desc}",
                  color: if(i == model.ac_index, do: color(:cyan), else: color(:white)),
                  attributes: if(i == model.ac_index, do: [attribute(:bold)], else: [])
                )
              end
            end
          end
        end
      ]
    end
  end

  defp autocomplete_rows(_model), do: []

  defp prompt_row(model) do
    row do
      column(size: 12) do
        panel(title: prompt_title(model), color: prompt_color(model)) do
          label(
            content: prompt_content(model),
            color: color(:white)
          )

          label(
            content: if(model.command_error, do: "Error: #{model.command_error}", else: ""),
            color: color(:red)
          )
        end
      end
    end
  end

  defp render_turn_card(%{agent_view: nil, command_output: output}) when not is_nil(output) do
    panel(title: "Shem // Interactive · Output", color: color(:cyan)) do
      for line <- String.split(output, "\n") do
        label(content: line, color: color(:white))
      end
    end
  end

  defp render_turn_card(%{agent_view: nil}) do
    panel(title: "Shem // Interactive · Agent Output", color: color(:cyan)) do
      label(content: "")
      label(
        content: "No active session.",
        attributes: [attribute(:bold)],
        color: color(:white)
      )
      label(content: "")
      label(
        content: "Type a task and press Enter to start an agent.",
        color: color(:cyan)
      )
      label(
        content: "Or use: /agent <preset> <task>",
        color: color(:cyan)
      )
      label(content: "")
      label(
        content: "Presets: general  coding  explore",
        color: color(:white)
      )
    end
  end

  defp render_turn_card(%{agent_view: view, focused_agent: name} = model) do
    status_str = status_label(view.status)
    shadow_str = shadow_indicator(Map.get(model, :shadow_band))
    title = "#{name} · turn #{view.turn_count}/#{view.max_turns} · #{status_str}#{shadow_str}"

    history_line =
      view.history
      |> Enum.map(fn %{turn: t, tool: tool} ->
        if tool, do: "t#{t}:#{tool}", else: "t#{t}:done"
      end)
      |> Enum.join("  ·  ")

    panel(title: title, color: status_color(view.status)) do
      label(
        content: "REASONING",
        attributes: [attribute(:bold)],
        color: color(:white)
      )

      label(
        content: truncate(view.streaming_buffer || view.current_reasoning || "waiting...", 200),
        color: color(:cyan)
      )

      label(content: "")

      label(
        content: "LAST TOOL CALL",
        attributes: [attribute(:bold)],
        color: color(:white)
      )

      case view.last_tool_call do
        nil ->
          label(content: "none", color: color(:white))

        tc ->
          label(content: "→ #{tc.name}", color: color(:green))
          label(content: truncate(inspect(tc.args), 120), color: color(:white))

          if tc.result do
            label(content: "← #{truncate(tc.result, 120)}", color: color(:white))
          end
      end

      label(content: "")

      label(
        content: "HISTORY",
        attributes: [attribute(:bold)],
        color: color(:white)
      )

      label(content: if(history_line == "", do: "no completed turns", else: history_line), color: color(:white))
    end
  end

  defp render_event_log(%{agent_view: nil}) do
    panel(title: "Event Log", color: color(:yellow)) do
      label(
        content: "No events yet.",
        attributes: [attribute(:bold)],
        color: color(:yellow)
      )
    end
  end

  defp render_event_log(%{agent_view: view}) do
    panel(title: "Event Log", color: color(:yellow)) do
      for event_type <- view.recent_events do
        label(content: to_string(event_type), color: color(:yellow))
      end
    end
  end

  defp render_agent_list(%{agents: []}) do
    panel(title: "Agents", color: color(:white)) do
      label(content: "none running", color: color(:white))
      label(content: "")
      label(content: "type a task +", color: color(:cyan))
      label(content: "Enter to start", color: color(:cyan))
    end
  end

  defp render_agent_list(%{agents: agents, focused_agent: focused}) do
    panel(title: "Agents (#{length(agents)})", color: color(:white)) do
      for a <- agents do
        marker = if a.name == focused, do: "●", else: "○"

        [
          label(
            content: "#{marker} #{a.name}",
            color: if(a.name == focused, do: color(:cyan), else: color(:white)),
            attributes: if(a.name == focused, do: [attribute(:bold)], else: [])
          ),
          label(content: "  #{agent_status_dot(a.status)} #{a.status} · t#{a.turn_count}", color: agent_status_color(a.status))
        ]
      end
    end
  end

  defp agent_status_dot(:running), do: "▶"
  defp agent_status_dot(:done), do: "✓"
  defp agent_status_dot(:error), do: "✗"
  defp agent_status_dot(:waiting), do: "◌"
  defp agent_status_dot(_), do: "?"

  defp agent_status_color(:running), do: color(:cyan)
  defp agent_status_color(:done), do: color(:green)
  defp agent_status_color(:error), do: color(:red)
  defp agent_status_color(:waiting), do: color(:yellow)
  defp agent_status_color(_), do: color(:white)

  defp prompt_title(%{paused: true}), do: "[ PAUSED — press SPACE to resume ]"
  defp prompt_title(%{command_buffer: "/" <> _ = buf}), do: "Command: #{buf}"
  defp prompt_title(%{active_fence: fence}) when not is_nil(fence),
    do: "[fence: #{fence}]  d=Dashboard  Tab=cycle  /fence clear=remove fence"
  defp prompt_title(_), do: "d=Dashboard  ↑↓/Tab=agents  /=command  Alt+Enter=newline"

  defp prompt_color(%{paused: true}), do: color(:red)
  defp prompt_color(_), do: color(:cyan)

  defp prompt_content(%{paused: true}), do: "PAUSED — press SPACE to resume."
  defp prompt_content(%{command_buffer: ""}), do: "> _"
  defp prompt_content(%{command_buffer: buf}), do: buf

  defp status_label(:running), do: "running"
  defp status_label(:done), do: "done"
  defp status_label(:error), do: "error"
  defp status_label(_), do: "unknown"

  defp status_color(:running), do: color(:cyan)
  defp status_color(:done), do: color(:green)
  defp status_color(:error), do: color(:red)
  defp status_color(_), do: color(:white)

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "…"

  defp shadow_indicator(nil), do: ""
  defp shadow_indicator(:high), do: "  ■ high"
  defp shadow_indicator(:medium), do: "  ■ med"
  defp shadow_indicator(:low), do: "  ■ low"
end
