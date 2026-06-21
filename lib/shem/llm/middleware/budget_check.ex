defmodule Shem.LLM.Middleware.BudgetCheck do
  @behaviour Shem.LLM.Middleware

  alias Shem.LLM.BudgetServer

  @impl true
  def call(%{model: :shadow} = request, _opts, next), do: next.(request)
  def call(request, opts, next), do: do_check(request, fn -> next.(request) end, opts)

  @impl true
  def stream(%{model: :shadow} = request, _opts, chunk_fn, next), do: next.(request, chunk_fn)
  def stream(request, opts, chunk_fn, next), do: do_check(request, fn -> next.(request, chunk_fn) end, opts)

  defp do_check(request, invoke_fn, opts) do
    server = Keyword.get(opts, :budget_server, BudgetServer)

    case BudgetServer.check(server) do
      {:error, :budget_exhausted} ->
        if request.session_id do
          Shem.EventLog.append(request.session_id, :budget_exhausted, %{})
        end

        {:error, :budget_exhausted}

      :ok ->
        result = invoke_fn.()

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
