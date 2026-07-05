defmodule Shem.MCP.Handlers.InvokeTool do
  alias Shem.Lab.{Registry, PortPool}
  alias Shem.MCP.Schema

  @schema %{
    "id" => %{"type" => "string"},
    "args" => %{"required" => false}
  }

  @spec call(map()) :: {:ok, any()} | {:error, atom()} | {:error, atom(), any()}
  def call(params) do
    with {:ok, valid} <- Schema.validate(params, @schema),
         {:ok, tool} <- Registry.lookup(valid["id"]) do
      args = Map.get(valid, "args", %{})

      case tool.runtime do
        {:beam, mod} ->
          with :ok <- ensure_loaded(tool),
               {:ok, _} <- Schema.validate(args, tool.input_schema) do
            try do
              {:ok, mod.run(args)}
            rescue
              e -> {:error, :runtime, Exception.message(e)}
            end
          end

        {:port, runtime_path} ->
          language = Map.get(tool.metadata, "language", "python")
          granted = Map.get(tool.metadata, "granted", %{})

          if Shem.Lab.Sandbox.requires_container?(granted) and
               is_nil(Application.get_env(:shem, :container_runtime_bin)) do
            {:error, :runtime, "tool requires a container runtime for its granted sandbox profile"}
          else
            with {:ok, pool} <-
                   Shem.Lab.PortPool.Supervisor.ensure_started(tool.id, runtime_path, language) do
              PortPool.call(pool, args)
            end
          end
      end
    end
  end

  defp ensure_loaded(%{runtime: {:beam, module}, source: source}) do
    case :code.is_loaded(module) do
      false ->
        # Tamper defense: stored source is re-scanned before any recompile.
        with :ok <- Shem.Lab.SourceScan.scan(source) do
          case Code.compile_string(source) do
            [{^module, bytecode} | _] ->
              case :code.load_binary(module, ~c"nofile", bytecode) do
                {:module, _} -> :ok
                {:error, _} -> {:error, :load_failed}
              end

            _ ->
              {:error, :load_failed}
          end
        end

      _ ->
        :ok
    end
  end
end
