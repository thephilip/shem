defmodule Shem.Adversarial.HardeningJob do
  use GenServer, restart: :temporary

  alias Shem.{Agent, EventLog, Lab}
  alias Shem.Agent.Config

  def start_link({tool_id, opts}) do
    GenServer.start_link(__MODULE__, tool_id, opts)
  end

  # ── Client API ─────────────────────────────────────────────────────────────

  def await(pid, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(pid, deadline)
  end

  defp do_await(pid, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case GenServer.call(pid, :status) do
        %{status: :done} -> :ok
        _ ->
          Process.sleep(20)
          do_await(pid, deadline)
      end
    end
  end

  # ── Init ───────────────────────────────────────────────────────────────────

  @impl true
  def init(tool_id) do
    max_rounds = Application.get_env(:shem, :adversarial_max_rounds, 5)

    case Lab.Registry.lookup(tool_id) do
      {:ok, tool} ->
        case EventLog.start_session() do
          {:ok, session_id} ->
            EventLog.append(session_id, :hardening_started, %{
              tool: tool.name,
              tool_id: tool_id,
              max_rounds: max_rounds
            })

            state = %{
              tool_id: tool_id,
              tool_name: tool.name,
              round: 0,
              max_rounds: max_rounds,
              session_id: session_id,
              status: :running
            }

            send(self(), :run_round)
            {:ok, state}

          {:error, reason} ->
            {:stop, reason}
        end

      {:error, :not_found} ->
        {:stop, :tool_not_found}
    end
  end

  # ── Callbacks ──────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{tool: state.tool_name, round: state.round, status: state.status}, state}
  end

  @impl true
  def handle_call(:session_id, _from, state) do
    {:reply, {:ok, state.session_id}, state}
  end

  @impl true
  def handle_info(:run_round, %{status: :running} = state) do
    EventLog.append(state.session_id, :hardening_round_started, %{
      round: state.round + 1,
      tool: state.tool_name
    })

    case Lab.Registry.lookup_by_name(state.tool_name) do
      {:ok, tool} ->
        run_red_team(state, tool)

      {:error, :not_found} ->
        {:noreply, finish(state, :error, 1)}
    end
  end

  def handle_info(:run_round, state), do: {:noreply, state}

  def handle_info({:red_team_done, {:ok, answer}}, state) do
    result = parse_red_team_result(answer)

    EventLog.append(state.session_id, :hardening_attack_complete, %{
      round: state.round + 1,
      failures_found: result != :clean,
      summary: if(result == :clean, do: nil, else: elem(result, 1))
    })

    case result do
      :clean ->
        {:noreply, finish(state, :clean, 1)}

      {:failures, summary} ->
        case Lab.Registry.lookup_by_name(state.tool_name) do
          {:ok, tool} -> run_target(state, tool, summary)
          {:error, :not_found} -> {:noreply, finish(state, :error, 1)}
        end
    end
  end

  def handle_info({:red_team_done, {:error, _reason}}, state) do
    {:noreply, finish(state, :error, 1)}
  end

  def handle_info({:target_done, {:ok, _}}, state) do
    new_round = state.round + 1

    EventLog.append(state.session_id, :hardening_patch_complete, %{
      round: new_round,
      tool: state.tool_name
    })

    new_state = %{state | round: new_round}

    if new_state.round >= new_state.max_rounds do
      {:noreply, finish(new_state, :max_rounds_reached)}
    else
      send(self(), :run_round)
      {:noreply, new_state}
    end
  end

  def handle_info({:target_done, {:error, _reason}}, state) do
    {:noreply, finish(state, :error, 1)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Loop helpers ───────────────────────────────────────────────────────────

  defp run_red_team(state, tool) do
    timeout = agent_timeout()
    parent = self()

    Task.start(fn ->
      result =
        case Agent.start(red_team_config(tool)) do
          {:ok, agent_name} ->
            await_result =
              try do
                Agent.await(agent_name, timeout)
              catch
                :exit, _ -> {:error, :timeout}
              end

            case await_result do
              {:ok, _} -> {:ok, get_red_team_answer(agent_name)}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      send(parent, {:red_team_done, result})
    end)

    {:noreply, state}
  end

  defp run_target(state, tool, summary) do
    timeout = agent_timeout()
    parent = self()

    Task.start(fn ->
      result =
        case Agent.start(target_config(tool, summary)) do
          {:ok, agent_name} ->
            try do
              Agent.await(agent_name, timeout)
            catch
              :exit, _ -> {:error, :timeout}
            end

          {:error, reason} ->
            {:error, reason}
        end

      send(parent, {:target_done, result})
    end)

    {:noreply, state}
  end

  defp agent_timeout do
    Application.get_env(:shem, :adversarial_agent_timeout_ms, 300_000)
  end

  defp finish(state, outcome, extra_round \\ 0) do
    EventLog.append(state.session_id, :hardening_completed, %{
      tool: state.tool_name,
      rounds: state.round + extra_round,
      outcome: outcome
    })

    %{state | status: :done}
  end

  # ── Agent configs ──────────────────────────────────────────────────────────

  defp red_team_config(tool) do
    %Config{
      task: "Find failures in #{tool.name}",
      system_prompt: """
      You are a red team agent. Your job is to find failures in the Elixir tool "#{tool.name}".
      Source:
      #{tool.source}

      Write StreamData property tests and targeted edge case tests using run_code.
      Each test must call the tool's run/1 function directly.

      When done, respond with exactly one of:
      FAILURES_FOUND: <one-line summary of what broke>
      NO_FAILURES_FOUND
      """,
      tools: ["run_code", "read_file"],
      max_turns: 10
    }
  end

  defp target_config(tool, failure_summary) do
    %Config{
      task: "Fix #{tool.name}",
      system_prompt: """
      You are a tool repair agent. The tool "#{tool.name}" has a known failure:
      #{failure_summary}

      Current source:
      #{tool.source}

      Rewrite the tool to fix this failure. Use write_tool to graduate the new version.
      The new version must pass its own tests before graduating.
      """,
      tools: ["write_tool", "run_code"],
      max_turns: 10
    }
  end

  # ── Result parsing ─────────────────────────────────────────────────────────

  defp parse_red_team_result(answer) do
    cond do
      String.contains?(answer, "FAILURES_FOUND:") ->
        summary = answer |> String.split("FAILURES_FOUND:") |> List.last() |> String.trim()
        {:failures, summary}

      String.contains?(answer, "NO_FAILURES_FOUND") ->
        :clean

      true ->
        # ambiguous — treat as clean to prevent infinite loops
        :clean
    end
  end

  defp get_red_team_answer(agent_name) do
    case Agent.session_id(agent_name) do
      {:ok, session_id} ->
        {:ok, events} = EventLog.events(session_id)

        events
        |> Enum.filter(&(&1.type == :agent_done))
        |> List.last()
        |> case do
          %{payload: %{content: content}} -> content
          _ -> ""
        end

      {:error, :not_found} ->
        ""
    end
  end
end
