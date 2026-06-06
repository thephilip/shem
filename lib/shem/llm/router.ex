defmodule Shem.LLM.Router do
  use GenServer

  @backend_modules %{
    llama_cpp: Shem.LLM.Middleware.LlamaCppTransport,
    ollama: Shem.LLM.Middleware.OllamaTransport
  }

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec resolve(atom()) :: {module(), keyword()} | {:error, :no_default}
  def resolve(model_atom) do
    GenServer.call(__MODULE__, {:resolve, model_atom})
  end

  @spec set_route(atom(), :llama_cpp | :ollama, String.t()) :: :ok
  def set_route(model_atom, backend_key, model_string) do
    GenServer.call(__MODULE__, {:set_route, model_atom, backend_key, model_string})
  end

  @spec all() :: %{atom() => {:llama_cpp | :ollama, String.t()}}
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl true
  def init(:ok) do
    {:ok, Application.get_env(:shem, :llm_routes, %{})}
  end

  @impl true
  def handle_call({:resolve, model_atom}, _from, routes) do
    result =
      case Map.fetch(routes, model_atom) do
        {:ok, {backend_key, model_string}} ->
          build_transport(backend_key, model_string)

        :error ->
          case Map.fetch(routes, :default) do
            {:ok, {backend_key, model_string}} -> build_transport(backend_key, model_string)
            :error -> {:error, :no_default}
          end
      end

    {:reply, result, routes}
  end

  def handle_call({:set_route, model_atom, backend_key, model_string}, _from, routes) do
    {:reply, :ok, Map.put(routes, model_atom, {backend_key, model_string})}
  end

  def handle_call(:all, _from, routes) do
    {:reply, routes, routes}
  end

  def handle_call(:flush, _from, _routes) do
    {:reply, :ok, Application.get_env(:shem, :llm_routes, %{})}
  end

  defp build_transport(backend_key, model_string) do
    case Map.fetch(@backend_modules, backend_key) do
      {:ok, module} -> {module, [model_string: model_string]}
      :error -> {:error, {:unknown_backend, backend_key}}
    end
  end
end
