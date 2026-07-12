defmodule Shem.MCP.Handlers.CounterfactualSelect do
  @spec call(map()) :: {:ok, map()} | {:error, :invalid_args, String.t()}
  def call(%{"run_id" => run_id, "branch_session_id" => branch_sid})
      when is_binary(run_id) and is_binary(branch_sid) do
    case Shem.Counterfactual.select(run_id, branch_sid) do
      {:ok, out} -> {:ok, out}
      {:error, :not_found} -> {:error, :invalid_args, "run_id not found"}
      {:error, :not_in_run} -> {:error, :invalid_args, "branch_session_id is not a branch of this run"}
    end
  end

  def call(_args), do: {:error, :invalid_args, "run_id and branch_session_id are required"}
end
