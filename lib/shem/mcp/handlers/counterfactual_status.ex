defmodule Shem.MCP.Handlers.CounterfactualStatus do
  @spec call(map()) :: {:ok, map()} | {:error, :invalid_args, String.t()}
  def call(%{"run_id" => run_id}) when is_binary(run_id) and run_id != "" do
    case Shem.Counterfactual.status(run_id) do
      {:ok, status} -> {:ok, status}
      {:error, :not_found} -> {:error, :invalid_args, "run_id not found"}
    end
  end

  def call(_args), do: {:error, :invalid_args, "run_id (string) is required"}
end
