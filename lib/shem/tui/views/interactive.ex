defmodule Shem.TUI.Views.Interactive do
  import Ratatouille.View
  import Ratatouille.Constants, only: [color: 1, attribute: 1]

  def render(model) do
    view do
      row do
        column(size: 8) do
          panel(title: "Shem // Interactive · Agent Output", color: color(:cyan)) do
            label(
              content: "No active session.",
              attributes: [attribute(:bold)],
              color: color(:white)
            )
            label(content: "")
            label(
              content: "Start an agent to stream output here.",
              attributes: [attribute(:bold)],
              color: color(:cyan)
            )
          end
        end

        column(size: 4) do
          panel(title: "Execution Log", color: color(:yellow)) do
            label(
              content: "No events yet.",
              attributes: [attribute(:bold)],
              color: color(:yellow)
            )
          end
        end
      end

      row do
        column(size: 12) do
          panel(title: prompt_title(model), color: prompt_color(model)) do
            label(
              content: prompt_content(model),
              attributes: [attribute(:bold)],
              color: color(:white)
            )
          end
        end
      end
    end
  end

  defp prompt_title(%{paused: true}), do: "[ PAUSED — press SPACE to resume ]"
  defp prompt_title(%{command_buffer: "/" <> _ = buf}), do: "Command: #{buf}"
  defp prompt_title(_), do: "d=Dashboard  /=Command  SPACE=Pause  q=Quit"

  defp prompt_color(%{paused: true}), do: color(:red)
  defp prompt_color(_), do: color(:cyan)

  defp prompt_content(%{paused: true}), do: "PAUSED — press SPACE to resume."
  defp prompt_content(%{command_buffer: ""}), do: "> _"
  defp prompt_content(%{command_buffer: buf}), do: buf
end
