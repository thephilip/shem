defmodule Shem.TUI.App do
  @behaviour Ratatouille.App

  alias Shem.TUI.Views.{Dashboard, Interactive}
  alias Shem.TUI.{CommandDispatch, AgentView}
  alias Ratatouille.Runtime.Subscription

  @esc 27
  @backspace 127
  @space ?\s
  @enter 13
  @tab 9

  @impl true
  def init(_context) do
    %{
      mode: :dashboard,
      command_buffer: "",
      paused: false,
      event_log_stats: %{sessions: 0, total_events: 0},
      tool_count: 0,
      mcp_client_count: 0,
      mcp_outbound_count: 0,
      cluster_node_count: 1,
      agents: [],
      focused_agent: nil,
      agent_view: nil,
      command_error: nil,
      command_output: nil,
      trust_counts: %{high: 0, medium: 0, low: 0, unrated: 0}
    }
  end

  @impl true
  def subscribe(_model) do
    Subscription.interval(500, :tick)
  end

  @impl true
  def update(model, msg) do
    case msg do
      {:event, %{ch: ?d, key: 0}} when model.command_buffer == "" ->
        %{model | mode: :dashboard}

      {:event, %{ch: ?i, key: 0}} when model.command_buffer == "" ->
        %{model | mode: :interactive}

      {:event, %{key: @space}} when model.command_buffer == "" ->
        %{model | paused: !model.paused}

      {:event, %{key: @esc}} when model.command_buffer == "" ->
        %{model | paused: true}

      {:event, %{ch: ?/}} when model.command_buffer == "" ->
        %{model | command_buffer: "/"}

      {:event, %{key: @backspace}} ->
        buf = model.command_buffer
        %{model | command_buffer: if(buf == "", do: "", else: String.slice(buf, 0..-2//1))}

      {:event, %{ch: ch}} when model.command_buffer != "" and ch > 0 ->
        %{model | command_buffer: model.command_buffer <> <<ch::utf8>>}

      {:event, %{key: @tab}} when model.command_buffer == "" ->
        case model.agents do
          [] ->
            model

          agents ->
            names = Enum.map(agents, & &1.name)

            next =
              case model.focused_agent do
                nil ->
                  List.first(names)

                current ->
                  idx = Enum.find_index(names, &(&1 == current)) || 0
                  Enum.at(names, rem(idx + 1, length(names)))
              end

            %{model | focused_agent: next}
        end

      {:event, %{key: @enter}} when model.command_buffer != "" ->
        case CommandDispatch.parse(model.command_buffer) do
          {:start_agent, preset_name, task} ->
            case Shem.Agent.start_with_preset(preset_name, task) do
              {:ok, name} ->
                %{model | command_buffer: "", focused_agent: name, command_error: nil, command_output: nil}

              {:error, reason} ->
                %{model | command_error: "failed to start agent: #{inspect(reason)}"}
            end

          {:stop_agent} ->
            if model.focused_agent, do: Shem.Agent.stop(model.focused_agent)
            %{model | command_buffer: "", command_error: nil, command_output: nil}

          {:list_agents} ->
            %{model | command_buffer: "", command_error: nil, command_output: nil}

          {:tools} ->
            output = format_tools()
            %{model | command_buffer: "", command_output: output, command_error: nil}

          {:trust, tool_name} ->
            case Shem.Lab.Registry.lookup_by_name(tool_name) do
              {:ok, tool} ->
                output = format_trust(tool)
                %{model | command_buffer: "", command_output: output, command_error: nil}

              {:error, :not_found} ->
                %{model | command_error: "unknown tool: #{tool_name}"}
            end

          {:redteam, tool_name} ->
            case Shem.Lab.Registry.lookup_by_name(tool_name) do
              {:ok, tool} ->
                Shem.Adversarial.start_hardening(tool.id)
                %{model | command_buffer: "", command_error: nil, command_output: nil}

              {:error, :not_found} ->
                %{model | command_error: "unknown tool: #{tool_name}"}
            end

          {:error, reason} ->
            %{model | command_error: reason, command_output: nil}
        end

      :tick ->
        %{
          model
          | event_log_stats: safe_stats(),
            tool_count: safe_tool_count(),
            mcp_client_count: safe_mcp_count(),
            mcp_outbound_count: safe_mcp_outbound_count(),
            cluster_node_count: safe_cluster_count(),
            agents: safe_agent_list(),
            agent_view: safe_agent_view(model.focused_agent),
            trust_counts: safe_trust_counts()
        }

      _ ->
        model
    end
  end

  @impl true
  def render(model) do
    case model.mode do
      :dashboard -> Dashboard.render(model)
      :interactive -> Interactive.render(model)
    end
  end

  defp format_tools do
    try do
      tools = Shem.Lab.Registry.all()
      scored = Shem.Trust.Store.all()

      if tools == [] do
        "No Lab tools graduated yet."
      else
        header = "Lab Tools (#{length(tools)})\n"

        lines =
          Enum.map(tools, fn tool ->
            {band, hardenings} =
              case Map.fetch(scored, tool.id) do
                {:ok, score} ->
                  count =
                    case Shem.Trust.Store.entry(tool.id) do
                      {:ok, entry} -> entry.hardening_count
                      _ -> 0
                    end

                  {score_to_band(score), count}

                :error ->
                  {:unrated, 0}
              end

            count_str = if hardenings == 1, do: "1 hardening", else: "#{hardenings} hardenings"
            "  #{String.pad_trailing(tool.name, 24)} #{String.pad_trailing(to_string(band), 10)} #{count_str}"
          end)

        header <> Enum.join(lines, "\n")
      end
    catch
      :exit, _ -> "Trust data unavailable."
    end
  end

  defp format_trust(tool) do
    try do
      case Shem.Trust.Store.entry(tool.id) do
        {:ok, entry} ->
          band = score_to_band(entry.score)
          updated = Calendar.strftime(entry.last_updated, "%Y-%m-%d %H:%M:%SZ")

          "#{tool.name}\n" <>
            "  band:       #{band}\n" <>
            "  score:      #{Float.round(entry.score, 3)}\n" <>
            "  hardenings: #{entry.hardening_count}\n" <>
            "  updated:    #{updated}"

        {:error, :unrated} ->
          "#{tool.name}\n  band: unrated\n  never hardened"
      end
    catch
      :exit, _ -> "#{tool.name}\n  trust data unavailable"
    end
  end

  defp safe_trust_counts do
    try do
      all_tools = Shem.Lab.Registry.all()
      scored = Shem.Trust.Store.all()
      base = %{high: 0, medium: 0, low: 0, unrated: 0}

      Enum.reduce(all_tools, base, fn tool, acc ->
        band =
          case Map.fetch(scored, tool.id) do
            {:ok, score} -> score_to_band(score)
            :error -> :unrated
          end

        Map.update!(acc, band, &(&1 + 1))
      end)
    catch
      :exit, _ -> %{high: 0, medium: 0, low: 0, unrated: 0}
    end
  end

  defp score_to_band(score) when score >= 0.8, do: :high
  defp score_to_band(score) when score >= 0.5, do: :medium
  defp score_to_band(_), do: :low

  defp safe_stats do
    try do
      Shem.EventLog.stats()
    catch
      :exit, _ -> %{sessions: 0, total_events: 0}
    end
  end

  defp safe_tool_count do
    try do
      Shem.Lab.Registry.all() |> length()
    catch
      :exit, _ -> 0
    end
  end

  defp safe_mcp_count do
    try do
      Shem.MCP.SessionRegistry.client_count()
    catch
      :exit, _ -> 0
    end
  end

  defp safe_mcp_outbound_count do
    try do
      Shem.MCP.Client.connected_servers()
      |> Enum.count(&(&1.status == :ready))
    catch
      :exit, _ -> 0
    end
  end

  defp safe_cluster_count do
    Shem.Cluster.nodes() |> length()
  end

  defp safe_agent_list do
    try do
      Horde.DynamicSupervisor.which_children(Shem.AgentSupervisor)
      |> Enum.filter(fn {_id, pid, _, _} -> is_pid(pid) end)
      |> Enum.map(fn {id, pid, _, _} ->
        status =
          case GenServer.call(pid, :status, 100) do
            {:ok, s} -> s
            _ -> :unknown
          end

        session_id =
          case GenServer.call(pid, :session_id, 100) do
            s when is_binary(s) -> s
            _ -> nil
          end

        %{name: id, pid: pid, status: status, session_id: session_id, turn_count: 0}
      end)
    catch
      :exit, _ -> []
    end
  end

  defp safe_agent_view(nil), do: nil

  defp safe_agent_view(name) do
    try do
      via = Shem.ProcessRegistry.via_tuple(name)

      case GenServer.whereis(via) do
        nil ->
          nil

        pid ->
          case GenServer.call(pid, :session_id, 200) do
            session_id when is_binary(session_id) ->
              case AgentView.build(session_id) do
                {:ok, view} -> %{view | agent_name: name}
                :not_found -> nil
              end

            _ ->
              nil
          end
      end
    catch
      :exit, _ -> nil
    end
  end
end
