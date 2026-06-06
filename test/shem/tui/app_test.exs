defmodule Shem.TUI.AppTest do
  use ExUnit.Case, async: false

  alias Shem.TUI.App

  describe "init/1" do
    test "default model starts in dashboard mode, unpaused, with empty buffer" do
      model = App.init(%{})
      assert model.mode == :dashboard
      assert model.command_buffer == ""
      assert model.paused == false
      assert model.event_log_stats == %{sessions: 0, total_events: 0}
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

  describe "update/2 — pause and resume" do
    test "space key toggles paused on" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: 0, key: ?\s}})
      assert result.paused == true
    end

    test "space key toggles paused off when already paused" do
      model = %{App.init(%{}) | paused: true}
      result = App.update(model, {:event, %{ch: 0, key: ?\s}})
      assert result.paused == false
    end

    test "esc key (27) always pauses" do
      model = App.init(%{})
      result = App.update(model, {:event, %{ch: 0, key: 27}})
      assert result.paused == true
    end

    test "pause keys are ignored while command buffer is open" do
      model = %{App.init(%{}) | command_buffer: "/"}
      result = App.update(model, {:event, %{ch: 0, key: ?\s}})
      assert result.paused == false
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
end
