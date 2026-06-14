defmodule Shem.TUI.App do
  @behaviour Ratatouille.App

  alias Shem.TUI.Views.{Dashboard, Interactive, History}
  alias Shem.TUI.{CommandDispatch, AgentView, StreamSink, Welcome}
  alias Ratatouille.Runtime.{Command, Subscription}
  import Ratatouille.View

  @esc 27
  @backspace 127
  @space ?\s
  @enter 13
  @tab 9
  @arrow_up 65517
  @arrow_down 65516
  @ctrl_k 11
  @ac_visible 6

  @impl true
  def init(_context) do
    show_welcome =
      if Welcome.first_launch?() do
        Welcome.mark_welcomed()
        true
      else
        false
      end

    %{
      mode: :dashboard,
      command_buffer: "",
      paused: false,
      event_log_stats: %{sessions: 0, total_events: 0},
      tool_count: 0,
      mcp_client_count: 0,
      mcp_outbound_count: 0,
      cluster_nodes: [],
      agents: [],
      focused_agent: nil,
      agent_view: nil,
      stream_sink: nil,
      command_error: nil,
      command_output: nil,
      trust_counts: %{high: 0, medium: 0, low: 0, unrated: 0},
      multiline_buffer: [],
      multiline_target: nil,
      history_sessions: [],
      history_cursor: 0,
      history_detail: nil,
      current_preset: "general",
      active_conversational_agent: nil,
      show_help: false,
      help_filter: "",
      show_welcome: show_welcome,
      shadow_band: nil,
      shadow_reasoning: "",
      active_fence: nil,
      tick_count: 0,
      system_stats: Shem.TUI.SystemStats.empty(),
      budget: %{tokens_used: 0, global_limit: 0},
      ac_index: 0
    }
  end

  @impl true
  def subscribe(_model) do
    Subscription.interval(100, :tick)
  end

  @impl true
  def update(model, msg) do
    case msg do
      # --- Welcome screen (dismiss on any key) ---
      {:event, _} when model.show_welcome ->
        %{model | show_welcome: false}

      # --- Help overlay ---
      {:event, %{key: @esc}} when model.show_help ->
        %{model | show_help: false, help_filter: ""}

      {:event, %{key: @backspace}} when model.show_help ->
        filter = model.help_filter
        %{model | help_filter: if(filter == "", do: "", else: String.slice(filter, 0..-2//1))}

      {:event, %{ch: ch}} when model.show_help and ch > 0 ->
        %{model | help_filter: model.help_filter <> <<ch::utf8>>}

      {:event, _} when model.show_help ->
        model

      # --- Multiline input mode (must be first) ---
      {:event, %{key: @esc}} when model.mode == :multiline_input ->
        %{model | mode: :interactive, multiline_buffer: [], multiline_target: nil, command_buffer: "", command_error: nil}

      {:event, %{key: @enter}} when model.mode == :multiline_input and model.command_buffer == "/done" ->
        text = Enum.join(model.multiline_buffer, "\n")
        submit_multiline(model, text)

      {:event, %{key: @enter}} when model.mode == :multiline_input ->
        %{model | multiline_buffer: model.multiline_buffer ++ [model.command_buffer], command_buffer: ""}

      {:event, %{key: @backspace}} when model.mode == :multiline_input ->
        buf = model.command_buffer
        %{model | command_buffer: if(buf == "", do: "", else: String.slice(buf, 0..-2//1))}

      {:event, %{ch: ch}} when model.mode == :multiline_input and ch > 0 ->
        %{model | command_buffer: model.command_buffer <> <<ch::utf8>>}

      {:event, _} when model.mode == :multiline_input ->
        model

      # --- History mode ---
      {:event, %{ch: ?h, key: 0}} when model.mode == :history ->
        %{model | mode: :interactive}

      {:event, %{key: @esc}} when model.mode == :history ->
        %{model | mode: :interactive}

      {:event, %{key: @arrow_up}} when model.mode == :history ->
        new_cursor = max(0, model.history_cursor - 1)
        %{model | history_cursor: new_cursor, history_detail: load_history_detail(model.history_sessions, new_cursor)}

      {:event, %{key: @arrow_down}} when model.mode == :history ->
        new_cursor = min(max(0, length(model.history_sessions) - 1), model.history_cursor + 1)
        %{model | history_cursor: new_cursor, history_detail: load_history_detail(model.history_sessions, new_cursor)}

      {:event, %{ch: ?r, key: 0}} when model.mode == :history ->
        case Enum.at(model.history_sessions, model.history_cursor) do
          nil ->
            model

          %{session_id: session_id, task: task} when not is_nil(task) ->
            case Shem.Agent.resume(session_id, task) do
              {:ok, name, _session_id} ->
                model = %{model | mode: :interactive, focused_agent: name, command_error: nil, command_output: nil}
                start_stream_sink_for_focused(model)

              {:error, reason} ->
                %{model | command_error: "resume failed: #{inspect(reason)}"}
            end

          _ ->
            %{model | command_error: "cannot resume: session has no task"}
        end

      {:event, _} when model.mode == :history ->
        model

      # --- Kill (Ctrl+K) ---
      {:event, %{key: @ctrl_k}} ->
        case model.focused_agent do
          nil -> model
          name ->
            Shem.Guardrails.kill_session(name)
            %{model |
              focused_agent: nil,
              active_fence: nil,
              command_output: "Agent stopped — use /history to branch from a prior event.",
              command_error: nil
            }
        end

      # --- Normal mode ---
      {:event, %{ch: ?d, key: 0}} when model.command_buffer == "" ->
        %{model | mode: :dashboard}

      {:event, %{ch: ?i, key: 0}} when model.command_buffer == "" ->
        %{model | mode: :interactive}

      {:event, %{ch: ?h, key: 0}} when model.command_buffer == "" ->
        sessions = safe_scan_history()
        detail = load_history_detail(sessions, 0)
        %{model | mode: :history, history_sessions: sessions, history_cursor: 0, history_detail: detail}

      {:event, %{key: @space}} when model.command_buffer == "" ->
        toggle_pause_focused(model)

      {:event, %{ch: ?/}} when model.command_buffer == "" ->
        %{model | command_buffer: "/", ac_index: 0}

      {:event, %{key: @backspace}} ->
        buf = model.command_buffer
        %{model | ac_index: 0, command_buffer: if(buf == "", do: "", else: String.slice(buf, 0..-2//1))}

      {:event, %{ch: ch}} when model.command_buffer != "" and ch > 0 ->
        %{model | command_buffer: model.command_buffer <> <<ch::utf8>>, ac_index: 0}

      {:event, %{key: @tab}} when model.command_buffer == "" ->
        cycle_focus(model, 1)

      {:event, %{key: @arrow_down}} when model.mode == :interactive and model.command_buffer == "" ->
        cycle_focus(model, 1)

      {:event, %{key: @arrow_up}} when model.mode == :interactive and model.command_buffer == "" ->
        cycle_focus(model, -1)

      {:event, %{key: @arrow_down}} when model.command_buffer != "" ->
        if String.starts_with?(model.command_buffer, "/") do
          max_index = min(length(current_suggestions(model)), @ac_visible) - 1
          %{model | ac_index: min(model.ac_index + 1, max(max_index, 0))}
        else
          model
        end

      {:event, %{key: @arrow_up}} when model.command_buffer != "" ->
        if String.starts_with?(model.command_buffer, "/") do
          %{model | ac_index: max(model.ac_index - 1, 0)}
        else
          model
        end

      {:event, %{key: @tab}} when model.command_buffer != "" ->
        if String.starts_with?(model.command_buffer, "/") do
          case Enum.at(current_suggestions(model), model.ac_index) do
            nil -> model
            suggestion -> %{model | command_buffer: Shem.TUI.Autocomplete.complete(suggestion), ac_index: 0}
          end
        else
          model
        end

      {:event, %{key: @enter, mod: 1}} when model.command_buffer != "" ->
        %{model | command_buffer: model.command_buffer <> "\n"}

      {:event, %{key: @enter}} when model.command_buffer != "" ->
        if String.starts_with?(model.command_buffer, "/") do
          case CommandDispatch.parse(model.command_buffer) do
            {:start_agent, preset_name, task} ->
              case Shem.Agent.start_with_preset(preset_name, task) do
                {:ok, name, _sid} ->
                  model = %{model | command_buffer: "", focused_agent: name, command_error: nil, command_output: nil}
                  start_stream_sink_for_focused(model)

                {:error, reason} ->
                  %{model | command_error: "failed to start agent: #{inspect(reason)}", command_output: nil}
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
                  %{model | command_error: "unknown tool: #{tool_name}", command_output: nil}
              end

            {:redteam, tool_name} ->
              case Shem.Lab.Registry.lookup_by_name(tool_name) do
                {:ok, tool} ->
                  Shem.Adversarial.start_hardening(tool.id)
                  %{model | command_buffer: "", command_error: nil, command_output: nil}

                {:error, :not_found} ->
                  %{model | command_error: "unknown tool: #{tool_name}", command_output: nil}
              end

            {:help} ->
              %{model | command_buffer: "", show_help: true, command_error: nil}

            {:preset_list} ->
              output = format_presets()
              %{model | command_buffer: "", command_output: output, command_error: nil}

            {:preset_add, name} ->
              %{model |
                mode: :multiline_input,
                multiline_target: {:preset_add, name},
                multiline_buffer: [],
                command_buffer: "",
                command_error: nil,
                command_output: nil
              }

            {:preset_delete, name} ->
              case Enum.find(Shem.Agent.Preset.all(), &(&1.name == name)) do
                nil ->
                  %{model | command_error: "unknown preset: #{name}", command_output: nil}

                %{source: :builtin} ->
                  %{model | command_error: "cannot delete built-in preset: #{name}", command_output: nil}

                %{source: :config} ->
                  %{model | command_error: "cannot delete config preset: #{name}", command_output: nil}

                %{source: :dynamic} ->
                  Shem.Agent.PresetStore.delete(name)
                  %{model | command_buffer: "", command_output: "preset '#{name}' deleted", command_error: nil}
              end

            {:preset_switch, name} ->
              if model.active_conversational_agent do
                Shem.Agent.stop(model.active_conversational_agent)
              end
              %{model |
                command_buffer: "",
                current_preset: name,
                active_conversational_agent: nil,
                command_output: "switched to preset: #{name}",
                command_error: nil
              }

            {:llm_route, results} ->
              Enum.each(results, fn {atom, backend_key, model_string} ->
                Shem.LLM.Router.set_route(atom, backend_key, model_string)
              end)

              routes_str =
                Enum.map_join(results, "\n", fn {atom, backend_key, model_string} ->
                  "  #{atom} → #{backend_key} · #{model_string}"
                end)

              %{model | command_buffer: "", command_output: "routes updated:\n#{routes_str}", command_error: nil}

            {:llm_routes} ->
              output = format_routes()
              %{model | command_buffer: "", command_output: output, command_error: nil}

            {:hire, name, role} ->
              command =
                Command.new(
                  fn ->
                    prompt =
                      "You are writing a system prompt for an AI agent.\n" <>
                      "Role description: \"#{role}\"\n" <>
                      "Write a concise system prompt (2-4 sentences) that describes the agent's purpose, approach, and any constraints.\n" <>
                      "Return ONLY the system prompt text. No explanation, no preamble, no quotes."

                    case Shem.LLM.complete(%Shem.LLM.Request{prompt: prompt, model: :default}) do
                      {:ok, response} -> {:ok, response.content}
                      {:error, reason} -> {:error, reason}
                    end
                  end,
                  {:hire_complete, name}
                )

              {%{model | command_buffer: "", command_output: "hiring #{name}...", command_error: nil}, command}

            {:shadow_info} ->
              band_str = if model.shadow_band, do: to_string(model.shadow_band), else: "no data"
              output = "shadow: #{band_str} — #{model.shadow_reasoning}"
              %{model | command_output: output, command_error: nil, command_buffer: ""}

            {:fence_set, path} ->
              if model.focused_agent do
                Shem.Agent.set_fence(model.focused_agent, path)
                %{model | command_buffer: "", active_fence: path,
                  command_output: "fence: #{path}", command_error: nil}
              else
                %{model | command_buffer: "", command_output: "no active agent — fence not set", command_error: nil}
              end

            {:fence_clear} ->
              if model.focused_agent, do: Shem.Agent.set_fence(model.focused_agent, nil)
              %{model | command_buffer: "", active_fence: nil,
                command_output: "fence cleared", command_error: nil}

            {:fence_show} ->
              output = if model.active_fence, do: "fence: #{model.active_fence}", else: "no fence active"
              %{model | command_buffer: "", command_output: output, command_error: nil}

            {:error, reason} ->
              %{model | command_error: reason, command_output: nil}
          end
        else
          # Plain text: steer a paused agent, otherwise conversational mode
          text = String.trim(model.command_buffer)

          if model.paused and model.focused_agent do
            case Shem.Agent.steer(model.focused_agent, text) do
              :ok ->
                %{model | command_buffer: "",
                  command_output: "steered — SPACE to resume", command_error: nil}

              {:error, reason} ->
                %{model | command_error: "steer failed: #{inspect(reason)}", command_output: nil}
            end
          else
            case model.active_conversational_agent do
              nil ->
                # Start a new conversational agent with the current preset
                case Shem.Agent.start_with_preset(model.current_preset, text, conversational: true) do
                  {:ok, name, _sid} ->
                    model = %{model | command_buffer: "", active_conversational_agent: name, focused_agent: name, command_error: nil, command_output: nil}
                    start_stream_sink_for_focused(model)

                  {:error, reason} ->
                    %{model | command_error: "failed to start conversational agent: #{inspect(reason)}", command_output: nil}
                end

              agent_name ->
                # Send message to the existing conversational agent
                case Shem.Agent.send_message(agent_name, text) do
                  :ok ->
                    %{model | command_buffer: "", command_error: nil}

                  {:error, reason} ->
                    %{model | command_buffer: "", command_error: "send_message failed: #{inspect(reason)}", command_output: nil}
                end
            end
          end
        end

      :tick ->
        tick_count = model.tick_count + 1

        {system_stats, budget} =
          if rem(tick_count, 10) == 1 do
            {Shem.TUI.SystemStats.collect(), safe_budget()}
          else
            {model.system_stats, model.budget}
          end

        agents = safe_agent_list()

        model = %{
          model
          | tick_count: tick_count,
            system_stats: system_stats,
            budget: budget,
            event_log_stats: safe_stats(),
            tool_count: safe_tool_count(),
            mcp_client_count: safe_mcp_count(),
            mcp_outbound_count: safe_mcp_outbound_count(),
            cluster_nodes: safe_cluster_nodes(),
            agents: agents,
            paused: focused_paused?(agents, model.focused_agent),
            agent_view: safe_agent_view(model.focused_agent),
            trust_counts: safe_trust_counts()
        }

        # Drain streaming tokens from StreamSink into streaming_buffer
        model =
          case model.stream_sink do
            nil -> model
            pid when is_pid(pid) ->
              if Process.alive?(pid) do
                tokens = StreamSink.take_tokens(pid)
                case tokens do
                  [] -> model
                  _ ->
                    new_buf = (model.agent_view && (model.agent_view.streaming_buffer || "")) <> Enum.join(tokens)
                    agent_view = model.agent_view && %{model.agent_view | streaming_buffer: new_buf}
                    %{model | agent_view: agent_view}
                end
              else
                %{model | stream_sink: nil}
              end
          end

        # Clear streaming_buffer when llm_call_completed is the most recent event
        model =
          if model.agent_view && :llm_call_completed in model.agent_view.recent_events do
            %{model | agent_view: %{model.agent_view | streaming_buffer: nil}}
          else
            model
          end

        # Stop StreamSink when agent is done or errored
        model =
          if model.agent_view && model.agent_view.status in [:done, :error] && model.stream_sink do
            StreamSink.stop(model.stream_sink)
            %{model | stream_sink: nil}
          else
            model
          end

        model = safe_shadow_update(model)
        model

      {{:hire_complete, name}, {:ok, system_prompt}} ->
        Shem.Agent.PresetStore.put(name, %{system_prompt: system_prompt, tools: :all})
        %{model | command_output: "hired: #{name}", command_error: nil}

      {{:hire_complete, _name}, {:error, reason}} ->
        %{model | command_output: "hire failed: #{inspect(reason)}", command_error: nil}

      _ ->
        model
    end
  end

  @impl true
  def render(model) do
    cond do
      model.show_welcome -> render_welcome()
      model.show_help -> render_help(model)
      true ->
        case model.mode do
          :dashboard -> Dashboard.render(model)
          :interactive -> Interactive.render(model)
          :multiline_input -> Interactive.render(model)
          :history -> History.render(model)
        end
    end
  end

  defp render_welcome do
    view do
      panel title: " ⬡ Welcome to Shem " do
        label(content: "")
        label(content: "  Your general-purpose AI agent platform.")
        label(content: "")
        label(content: "  Things to try:")
        label(content: "  • Ask me about your current project")
        label(content: "  • /preset coder  — switch to coding mode")
        label(content: "  • /preset security — review your code")
        label(content: "  • /help  — see all available commands")
        label(content: "")
        label(content: "  Press any key to begin...")
      end
    end
  end

  defp render_help(model) do
    filter = model.help_filter
    commands = CommandDispatch.commands()

    filtered =
      if filter == "" do
        commands
      else
        lower = String.downcase(filter)
        Enum.filter(commands, fn {cmd, desc} ->
          String.contains?(String.downcase(cmd), lower) or
            String.contains?(String.downcase(desc), lower)
        end)
      end

    view do
      panel title: " Commands — type to filter " do
        label(content: "  Filter: #{filter}_")
        label(content: "")
        for {cmd, desc} <- filtered do
          label(content: "  #{String.pad_trailing(cmd, 30)} #{desc}")
        end
        label(content: "")
        label(content: "  Press Escape to close")
      end
    end
  end

  defp submit_multiline(model, text) do
    case model.multiline_target do
      {:preset_add, name} ->
        Shem.Agent.PresetStore.put(name, %{system_prompt: text, tools: :all})

        %{model |
          mode: :interactive,
          multiline_buffer: [],
          multiline_target: nil,
          command_buffer: "",
          command_output: "preset '#{name}' saved",
          command_error: nil
        }

      _ ->
        %{model | mode: :interactive, multiline_buffer: [], multiline_target: nil, command_buffer: ""}
    end
  end

  defp format_presets do
    try do
      presets = Shem.Agent.Preset.all()

      if presets == [] do
        "No presets defined."
      else
        header = "Presets (#{length(presets)})\n"

        lines =
          Enum.map(presets, fn p ->
            source_str = String.pad_trailing("[#{p.source}]", 12)
            tools_str = if p.tools == :all, do: "all tools", else: Enum.join(p.tools, ", ")
            "  #{String.pad_trailing(p.name, 20)} #{source_str}  #{tools_str}"
          end)

        header <> Enum.join(lines, "\n")
      end
    catch
      :exit, _ -> "Preset data unavailable."
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

  defp format_routes do
    try do
      routes = Shem.LLM.Router.all()

      if routes == %{} do
        "No routes configured."
      else
        header = "routing table:\n"

        lines =
          routes
          |> Enum.sort_by(fn {k, _} -> to_string(k) end)
          |> Enum.map(fn {atom, {backend_key, model_string}} ->
            "  #{String.pad_trailing(to_string(atom), 12)} → #{backend_key} · #{model_string}"
          end)

        header <> Enum.join(lines, "\n")
      end
    catch
      :exit, _ -> "Router unavailable."
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

  defp safe_budget do
    try do
      status = Shem.LLM.BudgetServer.status()
      %{tokens_used: status.tokens_used, global_limit: status.global_limit}
    catch
      :exit, _ -> %{tokens_used: 0, global_limit: 0}
    end
  end

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

  defp safe_cluster_nodes do
    try do
      Shem.Cluster.members()
      |> Enum.map(fn n ->
        %{node: n, agents: Shem.Cluster.agent_count(n), status: :up}
      end)
    catch
      :exit, _ -> [%{node: Node.self(), agents: 0, status: :up}]
    end
  end

  defp safe_agent_list do
    try do
      Horde.DynamicSupervisor.which_children(Shem.AgentSupervisor)
      |> Enum.filter(fn {_id, pid, _, _} -> is_pid(pid) end)
      |> Enum.map(fn {id, pid, _, _} ->
        case safe_info(pid) do
          %{status: status, turn_count: turns, session_id: sid} ->
            %{name: id, pid: pid, status: status, session_id: sid, turn_count: turns, node: node(pid)}

          nil ->
            %{name: id, pid: pid, status: :unknown, session_id: nil, turn_count: 0, node: node(pid)}
        end
      end)
    catch
      :exit, _ -> []
    end
  end

  defp safe_info(pid) do
    try do
      GenServer.call(pid, :info, 100)
    catch
      :exit, _ -> nil
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

  defp load_history_detail([], _cursor), do: nil

  defp load_history_detail(sessions, cursor) do
    case Enum.at(sessions, cursor) do
      nil ->
        nil

      %{session_id: session_id} ->
        case Shem.EventLog.read_session_events(session_id) do
          {:ok, events} ->
            %{
              view: Shem.TUI.AgentView.from_events(events),
              transcript: Shem.TUI.AgentView.transcript(events)
            }

          _ ->
            nil
        end
    end
  end

  defp safe_shadow_update(%{focused_agent: nil} = model) do
    %{model | shadow_band: nil, shadow_reasoning: ""}
  end

  defp safe_shadow_update(%{focused_agent: name} = model) do
    try do
      case Shem.Shadow.Agent.current_score(name) do
        {:ok, %{band: band, reasoning: reasoning}} ->
          %{model | shadow_band: band, shadow_reasoning: reasoning}

        {:error, :not_found} ->
          %{model | shadow_band: nil, shadow_reasoning: ""}
      end
    rescue
      _ -> model
    catch
      :exit, _ -> model
    end
  end

  defp safe_scan_history do
    try do
      Shem.EventLog.HistoryScanner.scan()
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp start_stream_sink(model, session_id) do
    StreamSink.stop(model.stream_sink)
    {:ok, pid} = StreamSink.start_link(session_id)
    %{model | stream_sink: pid}
  end

  defp current_suggestions(model) do
    Shem.TUI.Autocomplete.suggest(model.command_buffer, CommandDispatch.commands())
  end

  defp toggle_pause_focused(%{focused_agent: nil} = model), do: model

  defp toggle_pause_focused(%{focused_agent: name} = model) do
    current = Enum.find(model.agents, &(&1.name == name))

    case current && current.status do
      :running ->
        case Shem.Agent.pause(name) do
          :ok ->
            %{model | paused: true,
              command_output: "paused #{name} — type to steer, SPACE to resume",
              command_error: nil}

          {:error, _} ->
            model
        end

      :paused ->
        case Shem.Agent.unpause(name) do
          :ok -> %{model | paused: false, command_output: nil}
          {:error, _} -> model
        end

      _ ->
        model
    end
  end

  defp focused_paused?(_agents, nil), do: false

  defp focused_paused?(agents, name),
    do: Enum.any?(agents, &(&1.name == name and &1.status == :paused))

  defp cycle_focus(model, delta) do
    case model.agents do
      [] ->
        model

      agents ->
        names = Enum.map(agents, & &1.name)

        idx =
          case model.focused_agent do
            nil ->
              if delta > 0, do: 0, else: length(names) - 1

            current ->
              current_idx = Enum.find_index(names, &(&1 == current)) || 0
              rem(current_idx + delta + length(names), length(names))
          end

        model = %{model | focused_agent: Enum.at(names, idx)}
        start_stream_sink_for_focused(model)
    end
  end

  defp start_stream_sink_for_focused(model) do
    case model.focused_agent do
      nil ->
        StreamSink.stop(model.stream_sink)
        %{model | stream_sink: nil}

      name ->
        try do
          via = Shem.ProcessRegistry.via_tuple(name)

          case GenServer.whereis(via) do
            nil ->
              model

            pid ->
              case GenServer.call(pid, :session_id, 200) do
                session_id when is_binary(session_id) ->
                  start_stream_sink(model, session_id)

                _ ->
                  model
              end
          end
        rescue
          _ -> model
        catch
          :exit, _ -> model
        end
    end
  end
end
