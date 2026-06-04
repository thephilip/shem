defmodule Shem.LLM.Middleware.BudgetCheck do
  @behaviour Shem.LLM.Middleware

  alias Shem.LLM.BudgetServer

  @impl true
  def call(request, opts, next) do
    server = Keyword.get(opts, :budget_server, BudgetServer)

    case BudgetServer.check(server) do
      {:error, :budget_exhausted} ->
        if request.session_id do
          Shem.EventLog.append(request.session_id, :budget_exhausted, %{})
        end

        {:error, :budget_exhausted}

      :ok ->
        result = next.(request)

        case result do
          {:ok, response} ->
            %{soft_warned?: was_warned} = BudgetServer.status(server)
            BudgetServer.deduct(server, response.tokens_used)
            %{soft_warned?: now_warned} = BudgetServer.status(server)

            if request.session_id && not was_warned && now_warned do
              Shem.EventLog.append(request.session_id, :budget_soft_warning, %{})
            end

          {:error, _} ->
            :ok
        end

        result
    end
  end
end
