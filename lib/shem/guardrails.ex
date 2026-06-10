defmodule Shem.Guardrails do
  alias Shem.Lab.Executor.Backend

  @fenced_tools ~w[read_file list_dir]

  @spec check_fence(nil | String.t(), String.t(), map(), keyword()) :: :ok | {:blocked, String.t()}
  def check_fence(nil, _tool, _args, _opts), do: :ok

  def check_fence(_fence, "shell", _args, opts) do
    if Keyword.get(opts, :backend) == Backend.Container,
      do: :ok,
      else: {:blocked, "shell is restricted inside a scope fence on a local executor"}
  end

  def check_fence(fence, tool, args, _opts) when tool in @fenced_tools do
    path = args["path"] || ""
    expanded = Path.expand(path)
    fence_abs = Path.expand(fence)

    if String.starts_with?(expanded, fence_abs) do
      :ok
    else
      {:blocked, "blocked by scope fence: #{path} is outside #{fence}"}
    end
  end

  def check_fence(_fence, _tool, _args, _opts), do: :ok

  @spec kill_session(String.t()) :: :ok | {:error, :not_found}
  def kill_session(name), do: Shem.Agent.stop(name)
end
