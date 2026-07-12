defmodule Shem.Sessions.Fork do
  @moduledoc """
  Session forking: copy a session's events up to a chosen `:llm_call_completed`
  event into a new session, optionally substituting the LLM content
  (`alt_response`). The primitive under the REST fork endpoint
  (`POST /api/sessions/:id/fork` — WebUI compare + co-driver) and the
  counterfactual run (ROADMAP Phase 9). Pure module, no Plug.
  """

  alias Shem.EventLog

  @doc "Exact-match fork target: the event must be an `:llm_call_completed`."
  @spec find_fork_event([map()], String.t()) ::
          {:ok, map()} | {:error, :fork_event_not_found | :not_llm_call}
  def find_fork_event(events, fork_event_id) do
    case Enum.find(events, &(&1.id == fork_event_id)) do
      nil -> {:error, :fork_event_not_found}
      event when event.type == :llm_call_completed -> {:ok, event}
      _event -> {:error, :not_llm_call}
    end
  end

  @doc """
  The last `:llm_call_completed` at-or-before the given event id — the only
  event type a fork accepts. MCP callers pass any event id and the constraint
  is absorbed here (Recall's resolve behavior); REST keeps exact-match.
  """
  @spec nearest_at_or_before([map()], String.t()) ::
          {:ok, map()} | {:error, :fork_event_not_found}
  def nearest_at_or_before(events, event_id) do
    case Enum.find_index(events, &(&1.id == event_id)) do
      nil ->
        {:error, :fork_event_not_found}

      idx ->
        events
        |> Enum.take(idx + 1)
        |> Enum.reverse()
        |> Enum.find(&(&1.type == :llm_call_completed))
        |> case do
          nil -> {:error, :fork_event_not_found}
          event -> {:ok, event}
        end
    end
  end

  @spec build_fork(String.t(), [map()], map(), String.t() | nil, boolean()) ::
          {:ok, String.t()} | {:error, term()}
  def build_fork(original_session_id, events, fork_event, alt_response, continue) do
    case EventLog.start_session() do
      {:ok, new_session_id} ->
        # Record provenance first: which session this branched from and at which
        # turn. Lets the UI label forks and re-open their compare-to-parent. The
        # UI filters branch_created out of the side-by-side lanes.
        EventLog.append(new_session_id, :branch_created, %{
          original_session_id: original_session_id,
          fork_event_id: fork_event.id
        })

        events_before = Enum.take_while(events, &(&1.id != fork_event.id))

        Enum.each(events_before, fn event ->
          EventLog.append(new_session_id, event.type, event.payload)
        end)

        fork_payload =
          if alt_response && alt_response != "" do
            Map.put(fork_event.payload, :content, alt_response)
          else
            fork_event.payload
          end

        EventLog.append(new_session_id, :llm_call_completed, fork_payload)
        # Static compare-fork is finalized; a continue-fork stays active so the
        # resumed agent can append to it.
        unless continue, do: EventLog.finalize(new_session_id)
        {:ok, new_session_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resume an agent on a continue-fork. `opts` are threaded to `Shem.Agent.resume/3`
  (the REST co-driver path passes `brain: :client` by contract). On failure the
  fork is finalized so it's a static snapshot, not a forever-"running" orphan.
  """
  @spec resume_fork(String.t(), [map()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def resume_fork(new_session_id, events, opts \\ []) do
    task = task_from_events(events)

    case Shem.Agent.resume(new_session_id, task, opts) do
      {:ok, agent_id, _} ->
        {:ok, agent_id}

      {:error, reason} ->
        EventLog.finalize(new_session_id)
        {:error, reason}
    end
  end

  @spec task_from_events([map()]) :: String.t()
  def task_from_events(events) do
    case Enum.find(events, &(&1.type == :agent_started)) do
      %{payload: p} -> Map.get(p, :task) || "Resumed fork"
      _ -> "Resumed fork"
    end
  end
end
