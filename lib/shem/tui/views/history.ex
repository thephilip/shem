defmodule Shem.TUI.Views.History do
  import Ratatouille.View
  import Ratatouille.Constants, only: [color: 1, attribute: 1]

  def render(model) do
    view do
      row do
        column(size: 4) do
          render_session_list(model)
        end

        column(size: 8) do
          render_session_detail(model)
        end
      end

      row do
        column(size: 12) do
          panel(title: "h/Esc=back  ↑↓=navigate  r=resume", color: color(:white)) do
            label(content: "", color: color(:white))
          end
        end
      end
    end
  end

  defp render_session_list(%{history_sessions: [], history_cursor: _}) do
    panel(title: "Session History", color: color(:yellow)) do
      label(content: "No past sessions found.", color: color(:yellow))
    end
  end

  defp render_session_list(%{history_sessions: sessions, history_cursor: cursor}) do
    panel(title: "Session History (#{length(sessions)})", color: color(:yellow)) do
      for {summary, i} <- Enum.with_index(sessions) do
        selected = i == cursor
        marker = if selected, do: "●", else: "○"
        task = truncate(summary.task || "(no task)", 22)
        meta = "  #{status_abbrev(summary.status)}·#{summary.turn_count}t·#{format_ago(summary.started_at)}"

        [
          label(
            content: "#{marker} #{String.pad_trailing(task, 22)}",
            color: if(selected, do: color(:cyan), else: color(:white)),
            attributes: if(selected, do: [attribute(:bold)], else: [])
          ),
          label(
            content: meta,
            color: status_color(summary.status)
          )
        ]
      end
    end
  end

  defp render_session_detail(%{history_detail: nil, history_sessions: []}) do
    panel(title: "Session Detail", color: color(:cyan)) do
      label(content: "No sessions found.", color: color(:white))
    end
  end

  defp render_session_detail(%{history_detail: nil, history_sessions: sessions, history_cursor: cursor}) do
    summary = Enum.at(sessions, cursor)
    title = if summary, do: "#{summary.session_id} · loading...", else: "Session Detail"

    panel(title: title, color: color(:cyan)) do
      label(content: "Loading session detail...", color: color(:white))
    end
  end

  defp render_session_detail(%{history_detail: %{view: view, transcript: transcript}, history_sessions: sessions, history_cursor: cursor}) do
    summary = Enum.at(sessions, cursor)
    title = if summary, do: "#{summary.session_id} · #{summary.task || "(no task)"}", else: "Session Detail"

    status_str =
      case view.status do
        :done -> "done"
        :error -> "error"
        :running -> "running"
        _ -> "unknown"
      end

    panel(title: title, color: status_color(view.status)) do
      label(
        content: "#{status_str} · #{view.turn_count} turns",
        attributes: [attribute(:bold)],
        color: status_color(view.status)
      )

      label(content: "")

      if transcript == [] do
        label(content: "No conversation recorded.", color: color(:white))
      else
        for entry <- transcript do
          transcript_labels(entry)
        end
      end
    end
  end

  defp transcript_labels({:user, text}) do
    [first | rest] = String.split(text, "\n")

    [
      label(content: "you ▸ #{first}", attributes: [attribute(:bold)], color: color(:cyan))
    ] ++ Enum.map(rest, &label(content: "      #{&1}", color: color(:cyan)))
  end

  defp transcript_labels({:assistant, text}) do
    [first | rest] = String.split(text, "\n")

    [
      label(content: "shem ▸ #{first}", color: color(:white))
    ] ++ Enum.map(rest, &label(content: "       #{&1}", color: color(:white)))
  end

  defp transcript_labels({:tool, line}) do
    [label(content: "  #{line}", color: color(:yellow))]
  end

  defp status_abbrev(:done), do: "✓"
  defp status_abbrev(:error), do: "✗"
  defp status_abbrev(:running), do: "▶"
  defp status_abbrev(:unknown), do: "?"
  defp status_abbrev(_), do: "?"

  defp status_color(:done), do: color(:green)
  defp status_color(:error), do: color(:red)
  defp status_color(:running), do: color(:cyan)
  defp status_color(:unknown), do: color(:white)
  defp status_color(_), do: color(:white)

  defp format_ago(nil), do: "—"

  defp format_ago(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "…"
end
