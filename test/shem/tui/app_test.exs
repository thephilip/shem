defmodule Shem.TUI.AppTest do
  use ExUnit.Case, async: false

  alias Shem.TUI.App

  # Ensure the welcome marker exists before any test runs so that App.init/1
  # always returns show_welcome: false regardless of test execution order.
  setup_all do
    Shem.TUI.Welcome.mark_welcomed()
    :ok
  end

  describe "init/1" do
    test "default model starts in dashboard mode, unpaused, with empty buffer" do
      model = App.init(%{})
      assert model.mode == :dashboard
      assert model.command_buffer == ""
      assert model.paused == false
      assert model.event_log_stats == %{sessions: 0, total_events: 0}
    end

    test "model has active_fence field defaulting to nil" do
      model = App.init(%{})
      assert Map.has_key?(model, :active_fence)
      assert model.active_fence == nil
    end
  end

  describe "update/2 — mode switching" do
    test "'d' key switches to dashboard mode" do
      model = %{App.init(%{}) | mode: :interactive}
      result = App.update(model, {:event, %{ch: ?d, key: 0}})
      assert result.mode == :dashboard
    end

    test "'i' key switches to interactive mode" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: ?i, key: 0}})
      assert result.mode == :interactive
    end

    test "mode keys are ignored while command buffer is open" do
      model = %{App.init(%{}) | command_buffer: "/st"}
      result = App.update(model, {:event, %{ch: ?i, key: 0}})
      assert result.mode == :dashboard
    end
  end

  describe "real pause (SPACE) and steering" do
    @space ?\s

    test "SPACE with no focused agent is a no-op" do
      model = %{base_model() | mode: :interactive}
      updated = App.update(model, {:event, %{key: @space, ch: 0, mod: 0}})
      assert updated.paused == false
    end

    test "SPACE on a vanished agent leaves the model unchanged" do
      model = %{
        base_model()
        | mode: :interactive,
          focused_agent: "agent_GONE",
          agents: [%{name: "agent_GONE", pid: self(), status: :running, session_id: nil, turn_count: 1}]
      }

      updated = App.update(model, {:event, %{key: @space, ch: 0, mod: 0}})
      assert updated.paused == false
    end

    test "Esc no longer sets paused" do
      model = %{base_model() | mode: :interactive}
      updated = App.update(model, {:event, %{key: 27, ch: 0, mod: 0}})
      assert updated.paused == false
    end

    test ":tick derives paused from the focused agent's real status" do
      Shem.LLM.StubTransport.Server.reset()

      Shem.LLM.StubTransport.Server.push_response(
        {:ok, %Shem.LLM.Response{content: "hi", tokens_used: 5, model: :default, latency_ms: 1}}
      )

      config = %Shem.Agent.Config{task: "chat", system_prompt: "s", conversational: true}
      {:ok, name, _sid} = Shem.Agent.start(config)
      {:ok, :waiting} = Shem.Agent.await(name, 2_000)
      on_exit(fn -> Shem.Agent.stop(name) end)

      # waiting agent: paused must derive false
      model = %{base_model() | focused_agent: name}
      ticked = App.update(model, :tick)
      assert ticked.paused == false
    end

    test "Enter steers instead of conversing when the focused agent is paused" do
      model = %{
        base_model()
        | mode: :interactive,
          paused: true,
          focused_agent: "agent_GONE",
          command_buffer: "change course"
      }

      updated = App.update(model, {:event, %{key: 13, ch: 0, mod: 0}})
      # agent_GONE doesn't exist -> steer fails -> error surfaced, buffer kept behavior:
      assert updated.command_error =~ "steer failed"
    end
  end

  describe "update/2 — command buffer" do
    test "'/' opens the command buffer" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: ?/, key: 0}})
      assert result.command_buffer == "/"
    end

    test "characters append to the buffer when it is active" do
      model = %{App.init(%{}) | command_buffer: "/"}
      result = App.update(model, {:event, %{ch: ?s, key: 0}})
      assert result.command_buffer == "/s"
    end

    test "backspace (127) removes the last character" do
      model = %{App.init(%{}) | command_buffer: "/st"}
      result = App.update(model, {:event, %{ch: 0, key: 127}})
      assert result.command_buffer == "/s"
    end

    test "backspace on empty buffer is a no-op" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: 0, key: 127}})
      assert result.command_buffer == ""
    end

    test "backspace on single-char buffer clears it" do
      model = %{App.init(%{}) | command_buffer: "/"}
      result = App.update(model, {:event, %{ch: 0, key: 127}})
      assert result.command_buffer == ""
    end
  end

  describe "update/2 — tick subscription" do
    test ":tick message updates event_log_stats from EventLog.stats()" do
      model = App.init(%{})
      updated = App.update(model, :tick)
      assert is_integer(updated.event_log_stats.sessions)
      assert is_integer(updated.event_log_stats.total_events)
    end
  end

  describe "init/1 — new Phase 9 fields" do
    test "model has agents list defaulting to empty" do
      model = App.init(%{})
      assert model.agents == []
    end

    test "model has focused_agent defaulting to nil" do
      model = App.init(%{})
      assert model.focused_agent == nil
    end

    test "model has agent_view defaulting to nil" do
      model = App.init(%{})
      assert model.agent_view == nil
    end

    test "model has command_error defaulting to nil" do
      model = App.init(%{})
      assert model.command_error == nil
    end
  end

  describe "update/2 — Tab key cycles focused_agent" do
    test "Tab with no agents is a no-op" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: 0, key: 9}})
      assert result.focused_agent == nil
    end

    test "Tab with agents and no focused agent focuses first" do
      model = %{App.init(%{}) | agents: [%{name: "a1", status: :running, session_id: "s1", turn_count: 0}]}
      result = App.update(model, {:event, %{ch: 0, key: 9}})
      assert result.focused_agent == "a1"
    end

    test "Tab cycles to next agent" do
      agents = [
        %{name: "a1", status: :running, session_id: "s1", turn_count: 0},
        %{name: "a2", status: :done, session_id: "s2", turn_count: 3}
      ]
      model = %{App.init(%{}) | agents: agents, focused_agent: "a1"}
      result = App.update(model, {:event, %{ch: 0, key: 9}})
      assert result.focused_agent == "a2"
    end

    test "Tab wraps around from last agent to first" do
      agents = [
        %{name: "a1", status: :running, session_id: "s1", turn_count: 0},
        %{name: "a2", status: :done, session_id: "s2", turn_count: 3}
      ]
      model = %{App.init(%{}) | agents: agents, focused_agent: "a2"}
      result = App.update(model, {:event, %{ch: 0, key: 9}})
      assert result.focused_agent == "a1"
    end

    test "Tab is ignored when command buffer is active" do
      agents = [%{name: "a1", status: :running, session_id: "s1", turn_count: 0}]
      model = %{App.init(%{}) | agents: agents, command_buffer: "/some"}
      result = App.update(model, {:event, %{ch: 0, key: 9}})
      assert result.focused_agent == nil
    end
  end

  describe "init/1 — Phase 11 fields" do
    test "model has command_output defaulting to nil" do
      model = App.init(%{})
      assert model.command_output == nil
    end

    test "model has trust_counts defaulting to all-zero map" do
      model = App.init(%{})
      assert model.trust_counts == %{high: 0, medium: 0, low: 0, unrated: 0}
    end
  end

  describe "update/2 — :tick with trust_counts" do
    test ":tick updates trust_counts to a map with the four band keys" do
      model = App.init(%{})
      updated = App.update(model, :tick)
      assert Map.has_key?(updated.trust_counts, :high)
      assert Map.has_key?(updated.trust_counts, :medium)
      assert Map.has_key?(updated.trust_counts, :low)
      assert Map.has_key?(updated.trust_counts, :unrated)
    end
  end

  describe "update/2 — /tools command" do
    test "enter with '/tools' buffer sets command_output and clears buffer" do
      model = %{App.init(%{}) | command_buffer: "/tools"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_buffer == ""
      assert is_binary(result.command_output)
    end
  end

  describe "update/2 — /trust command" do
    test "enter with '/trust unknown_tool' sets command_error for unknown tool" do
      model = %{App.init(%{}) | command_buffer: "/trust __no_such_tool__"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_error =~ "unknown tool"
    end

    test "starting an agent clears command_output" do
      model = %{App.init(%{}) | command_output: "some output", command_buffer: "/agent general do something"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_output == nil
    end

    test "enter with '/trust <known_tool>' sets command_output" do
      source = """
      defmodule AppTrustQueryTool#{System.unique_integer([:positive])} do
        def run(_args), do: :ok
      end
      """
      test_src = """
      defmodule AppTrustQueryToolTest#{System.unique_integer([:positive])} do
        def run, do: :ok
      end
      """
      {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
      lab_dir = Application.get_env(:shem, :lab_dir)
      on_exit(fn -> File.rm_rf!(lab_dir); Shem.Lab.Registry.flush() end)

      model = %{App.init(%{}) | command_buffer: "/trust #{tool.name}"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert is_binary(result.command_output)
      assert result.command_buffer == ""
    end
  end

  describe "update/2 — command_output cleared by other commands" do
    test "/stop clears command_output" do
      model = %{App.init(%{}) | command_output: "some output", command_buffer: "/stop"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_output == nil
    end

    test "/agents clears command_output" do
      model = %{App.init(%{}) | command_output: "some output", command_buffer: "/agents"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_output == nil
    end

    test "/redteam on a known tool clears command_output" do
      source = """
      defmodule AppRedteamClearTool#{System.unique_integer([:positive])} do
        def run(_args), do: :ok
      end
      """
      test_src = """
      defmodule AppRedteamClearToolTest#{System.unique_integer([:positive])} do
        def run, do: :ok
      end
      """
      {:ok, tool} = Shem.Lab.GraduationGate.run(source, test_src)
      lab_dir = Application.get_env(:shem, :lab_dir)
      on_exit(fn -> File.rm_rf!(lab_dir); Shem.Lab.Registry.flush() end)

      model = %{App.init(%{}) | command_output: "some output", command_buffer: "/redteam #{tool.name}"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_output == nil
    end
  end

  describe "init/1 — Phase 12 fields" do
    test "model has multiline_buffer defaulting to []" do
      assert App.init(%{}).multiline_buffer == []
    end

    test "model has multiline_target defaulting to nil" do
      assert App.init(%{}).multiline_target == nil
    end
  end

  describe "update/2 — /preset add enters multiline mode" do
    test "{:preset_add, name} switches mode to :multiline_input" do
      model = %{App.init(%{}) | command_buffer: "/preset add my_preset"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.mode == :multiline_input
      assert result.multiline_target == {:preset_add, "my_preset"}
      assert result.multiline_buffer == []
      assert result.command_buffer == ""
    end
  end

  describe "update/2 — multiline mode" do
    setup do
      Shem.Agent.PresetStore.flush()
      on_exit(fn -> Shem.Agent.PresetStore.flush() end)
      :ok
    end

    test "Enter appends command_buffer as a line and clears buffer" do
      model = %{App.init(%{}) | mode: :multiline_input, multiline_target: {:preset_add, "p"}, command_buffer: "line one"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.multiline_buffer == ["line one"]
      assert result.command_buffer == ""
      assert result.mode == :multiline_input
    end

    test "Enter with '/done' submits, saves preset, returns to :interactive" do
      model = %{App.init(%{}) | mode: :multiline_input, multiline_target: {:preset_add, "new_p"}, multiline_buffer: ["You are a reviewer."], command_buffer: "/done"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.mode == :interactive
      assert result.multiline_buffer == []
      assert result.multiline_target == nil
      assert result.command_buffer == ""
      assert is_binary(result.command_output)
      assert result.command_output =~ "new_p"
      assert {:ok, _} = Shem.Agent.PresetStore.get("new_p")
    end

    test "Escape cancels and returns to :interactive" do
      model = %{App.init(%{}) | mode: :multiline_input, multiline_target: {:preset_add, "p"}, multiline_buffer: ["some line"], command_buffer: "partial"}
      result = App.update(model, {:event, %{ch: 0, key: 27}})
      assert result.mode == :interactive
      assert result.multiline_buffer == []
      assert result.multiline_target == nil
      assert result.command_buffer == ""
    end

    test "typing appends to command_buffer" do
      model = %{App.init(%{}) | mode: :multiline_input, multiline_target: {:preset_add, "p"}, command_buffer: "hel"}
      result = App.update(model, {:event, %{ch: ?l, key: 0}})
      assert result.command_buffer == "hell"
    end

    test "Backspace removes last char from command_buffer in multiline mode" do
      model = %{App.init(%{}) | mode: :multiline_input, multiline_target: {:preset_add, "p"}, command_buffer: "hell"}
      result = App.update(model, {:event, %{ch: 0, key: 127}})
      assert result.command_buffer == "hel"
    end

    test "non-char key events are ignored in multiline mode" do
      model = %{App.init(%{}) | mode: :multiline_input, multiline_target: {:preset_add, "p"}, command_buffer: "abc"}
      result = App.update(model, {:event, %{ch: 0, key: 9}})
      assert result.mode == :multiline_input
      assert result.command_buffer == "abc"
    end
  end

  describe "update/2 — /preset list and /preset delete" do
    setup do
      Shem.Agent.PresetStore.flush()
      on_exit(fn -> Shem.Agent.PresetStore.flush() end)
      :ok
    end

    test "{:preset_list} sets command_output to a binary" do
      model = %{App.init(%{}) | command_buffer: "/preset list"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert is_binary(result.command_output)
    end

    test "{:preset_delete} on a built-in sets command_error" do
      model = %{App.init(%{}) | command_buffer: "/preset delete general"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_error =~ "cannot delete"
    end

    test "{:preset_delete} on a dynamic preset removes it and sets command_output" do
      Shem.Agent.PresetStore.put("temp_preset", %{system_prompt: "temp", tools: :all})
      model = %{App.init(%{}) | command_buffer: "/preset delete temp_preset"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_output =~ "temp_preset"
      assert {:error, :not_found} = Shem.Agent.PresetStore.get("temp_preset")
    end

    test "{:preset_delete} on unknown preset sets command_error" do
      model = %{App.init(%{}) | command_buffer: "/preset delete __nope__"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_error =~ "unknown preset"
    end
  end

  describe "history mode" do
    alias Shem.EventLog.HistoryScanner

    defp history_summary(opts \\ []) do
      %HistoryScanner{
        session_id: Keyword.get(opts, :session_id, "ses_HIST_TEST"),
        task: Keyword.get(opts, :task, "hist task"),
        started_at: Keyword.get(opts, :started_at, DateTime.utc_now()),
        status: Keyword.get(opts, :status, :done),
        turn_count: Keyword.get(opts, :turn_count, 2)
      }
    end

    test "h key enters :history mode" do
      model = App.init(%{})
      updated = App.update(model, {:event, %{ch: ?h, key: 0}})
      assert updated.mode == :history
    end

    test "h key in :history mode returns to :interactive" do
      model = App.init(%{}) |> Map.put(:mode, :history)
      updated = App.update(model, {:event, %{ch: ?h, key: 0}})
      assert updated.mode == :interactive
    end

    test "Esc in :history mode returns to :interactive" do
      model = App.init(%{}) |> Map.put(:mode, :history)
      updated = App.update(model, {:event, %{key: 27}})
      assert updated.mode == :interactive
    end

    test "arrow_down increments history_cursor" do
      summaries = [history_summary(session_id: "a"), history_summary(session_id: "b")]
      model = App.init(%{}) |> Map.merge(%{mode: :history, history_sessions: summaries, history_cursor: 0})
      updated = App.update(model, {:event, %{key: 65516}})
      assert updated.history_cursor == 1
    end

    test "arrow_down clamps at last session" do
      summaries = [history_summary()]
      model = App.init(%{}) |> Map.merge(%{mode: :history, history_sessions: summaries, history_cursor: 0})
      updated = App.update(model, {:event, %{key: 65516}})
      assert updated.history_cursor == 0
    end

    test "arrow_up decrements history_cursor" do
      summaries = [history_summary(session_id: "a"), history_summary(session_id: "b")]
      model = App.init(%{}) |> Map.merge(%{mode: :history, history_sessions: summaries, history_cursor: 1})
      updated = App.update(model, {:event, %{key: 65517}})
      assert updated.history_cursor == 0
    end

    test "arrow_up clamps at 0" do
      summaries = [history_summary()]
      model = App.init(%{}) |> Map.merge(%{mode: :history, history_sessions: summaries, history_cursor: 0})
      updated = App.update(model, {:event, %{key: 65517}})
      assert updated.history_cursor == 0
    end

    test "h key does not enter history when command_buffer is non-empty" do
      model = App.init(%{})
      updated = App.update(model, {:event, %{ch: ?h, key: 0}})
      # h key enters history mode since buffer is empty in init
      assert updated.mode == :history

      # But with non-empty buffer, h appends to it
      model2 = App.init(%{}) |> Map.merge(%{mode: :interactive, command_buffer: "/foo"})
      updated2 = App.update(model2, {:event, %{ch: ?h, key: 0}})
      assert updated2.mode == :interactive
      assert updated2.command_buffer == "/foo" <> <<(?h)::utf8>>
    end
  end

  describe "init/1 — Phase 28 fields" do
    test "model has current_preset defaulting to 'general'" do
      model = App.init(%{})
      assert model.current_preset == "general"
    end

    test "model has active_conversational_agent defaulting to nil" do
      model = App.init(%{})
      assert model.active_conversational_agent == nil
    end

    test "model has show_help defaulting to false" do
      model = App.init(%{})
      assert model.show_help == false
    end

    test "model has help_filter defaulting to empty string" do
      model = App.init(%{})
      assert model.help_filter == ""
    end
  end

  describe "update/2 — /help command" do
    test "/help sets show_help to true and clears command_buffer" do
      model = %{App.init(%{}) | command_buffer: "/help"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.show_help == true
      assert result.command_buffer == ""
      assert result.command_error == nil
    end
  end

  describe "update/2 — /preset switch" do
    test "/preset coder sets current_preset and shows status" do
      model = %{App.init(%{}) | command_buffer: "/preset coder"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.current_preset == "coder"
      assert result.command_output =~ "coder"
      assert result.command_buffer == ""
      assert result.command_error == nil
    end

    test "/preset switch with active conversational agent stops it and clears it" do
      model = %{App.init(%{}) | command_buffer: "/preset coder", active_conversational_agent: "fake_agent_xyz"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.current_preset == "coder"
      assert result.active_conversational_agent == nil
    end
  end

  describe "update/2 — conversational mode (plain text)" do
    test "plain text with no active agent starts a conversational agent" do
      model = %{App.init(%{}) | command_buffer: "hello from conversational mode"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_buffer == ""
      assert is_binary(result.active_conversational_agent)
      assert result.active_conversational_agent != nil
      assert result.focused_agent == result.active_conversational_agent
      # Clean up the spawned agent
      on_exit(fn ->
        if result.active_conversational_agent do
          Shem.Agent.stop(result.active_conversational_agent)
        end
      end)
    end

    test "plain text with active agent calls send_message" do
      # Start a real conversational agent first
      {:ok, agent_name, _} = Shem.Agent.start_with_preset("general", "chat session", conversational: true)
      # Wait for it to reach :waiting
      :timer.sleep(100)
      model = %{App.init(%{}) | command_buffer: "how are you?", active_conversational_agent: agent_name}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_buffer == ""
      # send_message returns :ok or error — either way buffer clears
      on_exit(fn -> Shem.Agent.stop(agent_name) end)
    end
  end

  describe "welcome screen" do
    test "model has show_welcome field" do
      model = App.init(%{})
      assert Map.has_key?(model, :show_welcome)
      assert is_boolean(model.show_welcome)
    end

    test "any keypress dismisses welcome screen" do
      model = %{App.init(%{}) | show_welcome: true}
      result = App.update(model, {:event, %{ch: ?a, key: 0}})
      assert result.show_welcome == false
    end

    test "non-character key dismisses welcome screen" do
      model = %{App.init(%{}) | show_welcome: true}
      result = App.update(model, {:event, %{ch: 0, key: 27}})
      assert result.show_welcome == false
    end

    test "welcome screen does not process other commands while active" do
      model = %{App.init(%{}) | show_welcome: true, mode: :dashboard}
      result = App.update(model, {:event, %{ch: ?i, key: 0}})
      # Mode should NOT switch — welcome consumes the event
      assert result.mode == :dashboard
      assert result.show_welcome == false
    end
  end

  describe "/help overlay" do
    test "typing when show_help: true appends to help_filter" do
      model = %{App.init(%{}) | show_help: true, help_filter: ""}
      result = App.update(model, {:event, %{ch: ?p, key: 0}})
      assert result.help_filter == "p"
    end

    test "typing multiple characters appends each" do
      model = %{App.init(%{}) | show_help: true, help_filter: "pre"}
      result = App.update(model, {:event, %{ch: ?s, key: 0}})
      assert result.help_filter == "pres"
    end

    test "backspace removes last char from help_filter" do
      model = %{App.init(%{}) | show_help: true, help_filter: "pre"}
      result = App.update(model, {:event, %{ch: 0, key: 127}})
      assert result.help_filter == "pr"
    end

    test "backspace on empty help_filter is a no-op" do
      model = %{App.init(%{}) | show_help: true, help_filter: ""}
      result = App.update(model, {:event, %{ch: 0, key: 127}})
      assert result.help_filter == ""
      assert result.show_help == true
    end

    test "escape closes help overlay and clears filter" do
      model = %{App.init(%{}) | show_help: true, help_filter: "test"}
      result = App.update(model, {:event, %{ch: 0, key: 27}})
      assert result.show_help == false
      assert result.help_filter == ""
    end

    test "non-printable non-escape key when show_help is a no-op" do
      model = %{App.init(%{}) | show_help: true, help_filter: "abc"}
      result = App.update(model, {:event, %{ch: 0, key: 9}})
      assert result.show_help == true
      assert result.help_filter == "abc"
    end
  end

  describe "update/2 — Ctrl+K kill" do
    @ctrl_k 11

    test "with active agent: stops agent and sets command_output" do
      model = %{App.init(%{}) | focused_agent: "fake_agent_xyz"}
      result = App.update(model, {:event, %{key: @ctrl_k}})
      assert result.focused_agent == nil
      assert result.command_output =~ "Agent stopped"
      assert result.active_fence == nil
    end

    test "with no active agent: no-op" do
      model = App.init(%{})
      result = App.update(model, {:event, %{key: @ctrl_k}})
      assert result == model
    end
  end

  describe "update/2 — /fence dispatch" do
    @enter 13

    test "/fence <path> with no active agent shows 'no active agent' message" do
      model = %{App.init(%{}) | command_buffer: "/fence /tmp/proj"}
      result = App.update(model, {:event, %{key: @enter}})
      assert result.active_fence == nil
      assert result.command_buffer == ""
      assert result.command_output =~ "no active agent"
    end

    test "/fence clear clears active_fence" do
      model = %{App.init(%{}) | command_buffer: "/fence clear", active_fence: "/tmp/proj"}
      result = App.update(model, {:event, %{key: @enter}})
      assert result.active_fence == nil
      assert result.command_output =~ "cleared"
    end

    test "/fence show with active fence displays path" do
      model = %{App.init(%{}) | command_buffer: "/fence", active_fence: "/tmp/proj"}
      result = App.update(model, {:event, %{key: @enter}})
      assert result.command_output =~ "/tmp/proj"
      assert result.command_buffer == ""
    end

    test "/fence show with no fence displays 'no fence active'" do
      model = %{App.init(%{}) | command_buffer: "/fence"}
      result = App.update(model, {:event, %{key: @enter}})
      assert result.command_output =~ "no fence active"
    end
  end

  describe "history resume (r key)" do
    test "r on a session with a task resumes it and switches to interactive" do
      Shem.LLM.StubTransport.Server.reset()

      Shem.LLM.StubTransport.Server.push_response(
        {:ok, %Shem.LLM.Response{content: "resumed", tokens_used: 5, model: :default, latency_ms: 1}}
      )

      session_id = "ses_RESUME_#{System.unique_integer([:positive])}"
      {:ok, ^session_id} = Shem.EventLog.start_session(session_id)

      model = %{
        base_model()
        | mode: :history,
          history_sessions: [%{session_id: session_id, task: "resume me"}],
          history_cursor: 0
      }

      updated = App.update(model, {:event, %{ch: ?r, key: 0, mod: 0}})

      assert updated.mode == :interactive
      assert is_binary(updated.focused_agent)

      Shem.Agent.stop(updated.focused_agent)
    end
  end

  # Hand-built model that matches App.init/1 but with show_welcome: false,
  # avoiding side effects (welcome-marker file write) during tests.
  defp base_model do
    %{
      mode: :dashboard,
      command_buffer: "",
      paused: false,
      event_log_stats: %{sessions: 0, total_events: 0},
      tool_count: 0,
      mcp_client_count: 0,
      mcp_outbound_count: 0,
      cluster_node_count: 1,
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
      show_welcome: false,
      shadow_band: nil,
      shadow_reasoning: "",
      active_fence: nil,
      tick_count: 0,
      system_stats: Shem.TUI.SystemStats.empty(),
      budget: %{tokens_used: 0, global_limit: 0},
      ac_index: 0
    }
  end

  describe "dashboard live stats" do
    test ":tick populates system_stats and budget on the first tick" do
      model = base_model()
      updated = App.update(model, :tick)
      assert %{cpu: _, mem_used_mb: _, mem_total_mb: _} = updated.system_stats
      assert %{tokens_used: used, global_limit: limit} = updated.budget
      assert is_integer(used) and is_integer(limit)
      assert updated.tick_count == 1
    end

    test ":tick only refreshes system stats every 10th tick" do
      model = %{base_model() | tick_count: 1, system_stats: %{cpu: 99.9, mem_used_mb: 1, mem_total_mb: 2}}
      updated = App.update(model, :tick)
      assert updated.system_stats == %{cpu: 99.9, mem_used_mb: 1, mem_total_mb: 2}
    end
  end

  describe "agent focus cycling" do
    defp with_agents(model) do
      agents = [
        %{name: "agent_A", pid: self(), status: :running, session_id: nil, turn_count: 1},
        %{name: "agent_B", pid: self(), status: :done, session_id: nil, turn_count: 2}
      ]

      %{model | mode: :interactive, agents: agents}
    end

    test "arrow down focuses the first agent when none focused" do
      model = with_agents(base_model())
      updated = App.update(model, {:event, %{key: 65516, ch: 0, mod: 0}})
      assert updated.focused_agent == "agent_A"
    end

    test "arrow down cycles forward and wraps" do
      model = %{with_agents(base_model()) | focused_agent: "agent_B"}
      updated = App.update(model, {:event, %{key: 65516, ch: 0, mod: 0}})
      assert updated.focused_agent == "agent_A"
    end

    test "arrow up cycles backward" do
      model = %{with_agents(base_model()) | focused_agent: "agent_A"}
      updated = App.update(model, {:event, %{key: 65517, ch: 0, mod: 0}})
      assert updated.focused_agent == "agent_B"
    end

    test "arrows do nothing while typing a command" do
      model = %{with_agents(base_model()) | command_buffer: "/age"}
      updated = App.update(model, {:event, %{key: 65516, ch: 0, mod: 0}})
      assert updated.focused_agent == nil
    end
  end

  describe "update/2 — /llm commands" do
    setup do
      Shem.LLM.Router.flush()
      on_exit(fn -> Shem.LLM.Router.flush() end)
      :ok
    end

    test "/llm route sets route and updates command_output" do
      model = %{App.init(%{}) | mode: :interactive, command_buffer: "/llm route reasoning=phi4"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_output =~ "routes updated"
      assert result.command_output =~ "reasoning"
      assert result.command_output =~ "llama_cpp"
      assert result.command_output =~ "phi4"
      assert result.command_buffer == ""
      assert result.command_error == nil
      # verify Router state was actually updated
      assert {_, opts} = Shem.LLM.Router.resolve(:reasoning)
      assert Keyword.get(opts, :model_string) == "phi4"
    end

    test "/llm routes renders route table into command_output" do
      model = %{App.init(%{}) | mode: :interactive, command_buffer: "/llm routes"}
      result = App.update(model, {:event, %{ch: 0, key: 13}})
      assert result.command_output =~ "routing table"
      assert result.command_output =~ "default"
      assert result.command_buffer == ""
      assert result.command_error == nil
    end
  end

  describe "slash-command autocomplete" do
    test "typing resets ac_index" do
      model = %{base_model() | command_buffer: "/pre", ac_index: 2}
      updated = App.update(model, {:event, %{ch: ?s, key: 0, mod: 0}})
      assert updated.ac_index == 0
      assert updated.command_buffer == "/pres"
    end

    test "arrow down moves the selection" do
      model = %{base_model() | command_buffer: "/preset", ac_index: 0}
      updated = App.update(model, {:event, %{key: 65516, ch: 0, mod: 0}})
      assert updated.ac_index == 1
    end

    test "arrow up clamps at zero" do
      model = %{base_model() | command_buffer: "/preset", ac_index: 0}
      updated = App.update(model, {:event, %{key: 65517, ch: 0, mod: 0}})
      assert updated.ac_index == 0
    end

    test "tab completes the selected suggestion" do
      model = %{base_model() | command_buffer: "/he", ac_index: 0}
      updated = App.update(model, {:event, %{key: 9, ch: 0, mod: 0}})
      assert updated.command_buffer == "/help "
    end

    test "tab with no matches leaves the buffer alone" do
      model = %{base_model() | command_buffer: "/zzz", ac_index: 0}
      updated = App.update(model, {:event, %{key: 9, ch: 0, mod: 0}})
      assert updated.command_buffer == "/zzz"
    end

    test "arrow down cannot move the selection past the rendered window" do
      # bare "/" matches every command (18), but only 6 render
      model = %{base_model() | command_buffer: "/", ac_index: 0}

      final =
        Enum.reduce(1..10, model, fn _, m ->
          App.update(m, {:event, %{key: 65516, ch: 0, mod: 0}})
        end)

      assert final.ac_index == 5
    end
  end

  describe "multiline prompt (Alt+Enter)" do
    test "alt+enter appends a newline to a non-empty buffer" do
      model = %{base_model() | mode: :interactive, command_buffer: "first line"}
      updated = App.update(model, {:event, %{key: 13, mod: 1, ch: 0}})
      assert updated.command_buffer == "first line\n"
    end

    test "alt+enter on an empty buffer does nothing" do
      model = %{base_model() | mode: :interactive, command_buffer: ""}
      updated = App.update(model, {:event, %{key: 13, mod: 1, ch: 0}})
      assert updated.command_buffer == ""
    end

    test "plain enter still submits (buffer cleared) for slash commands" do
      model = %{base_model() | mode: :interactive, command_buffer: "/agents"}
      updated = App.update(model, {:event, %{key: 13, mod: 0, ch: 0}})
      assert updated.command_buffer == ""
    end
  end
end
