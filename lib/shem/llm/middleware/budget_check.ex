defmodule Shem.LLM.Middleware.BudgetCheck do
  @behaviour Shem.LLM.Middleware

  alias Shem.LLM.BudgetServer

  @impl true
  def call(request, opts, next) do
    server = Keyword.get(opts, :budget_server, BudgetServer)

    case BudgetServer.check(server) do
      {:error, :budget_exhausted} ->
        {:error, :budget_exhausted}

      :ok ->
        result = next.(request)

        case result do
          {:ok, response} -> BudgetServer.deduct(server, response.tokens_used)
          {:error, _} -> :ok
        end

        result
    end
  end
end
