defmodule Shem.Guardrails do
  alias Shem.Lab.Executor.Backend

  @fenced_tools ~w[read_file list_dir write_file]

  @spec check_fence(nil | String.t(), String.t(), map(), keyword()) :: :ok | {:blocked, String.t()}
  def check_fence(nil, _tool, _args, _opts), do: :ok

  def check_fence(_fence, "shell", _args, opts) do
    if Keyword.get(opts, :backend) == Backend.Container,
      do: :ok,
      else: {:blocked, "shell is restricted inside a scope fence on a local executor"}
  end

  def check_fence(_fence, "run_code", _args, opts) do
    if Keyword.get(opts, :backend) == Backend.Container,
      do: :ok,
      else: {:blocked, "run_code is restricted inside a scope fence on a local executor"}
  end

  def check_fence(fence, tool, args, _opts) when tool in @fenced_tools do
    path = args["path"] || ""
    expanded = Path.expand(path)
    fence_abs = Path.expand(fence)

    # Symlinks are not resolved — checked as the literal path the caller provided.
    if expanded == fence_abs or String.starts_with?(expanded, fence_abs <> "/") do
      :ok
    else
      {:blocked, "blocked by scope fence: #{path} is outside #{fence}"}
    end
  end

  def check_fence(_fence, _tool, _args, _opts), do: :ok

  @spec check_action(String.t(), map(), keyword()) :: :ok | {:blocked, String.t()}
  def check_action(tool, args, opts) do
    host_deny = Application.get_env(:shem, :tool_policy, %{}) |> Map.get(:deny, [])
    agent_deny = (Keyword.get(opts, :policy) || %{}) |> Map.get(:deny, [])
    deny = host_deny ++ agent_deny
    declared = Keyword.get(opts, :actions)
    action = args["action"]

    cond do
      tool in deny ->
        {:blocked, "blocked by policy: #{tool}"}

      is_list(declared) and (not is_binary(action) or action not in declared) ->
        {:blocked, "#{tool}: action #{inspect(action)} is not in the tool's declared actions"}

      is_binary(action) and "#{tool}.#{action}" in deny ->
        {:blocked, "blocked by policy: #{tool}.#{action}"}

      true ->
        :ok
    end
  end

  @spec kill_session(String.t()) :: :ok | {:error, :not_found}
  def kill_session(name), do: Shem.Agent.stop(name)
end
