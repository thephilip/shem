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

      declared =
        case tool.metadata["actions"] do
          l when is_list(l) and l != [] -> Enum.map(l, & &1["name"])
          _ -> nil
        end

      case Shem.Guardrails.check_action(tool.name, args, policy: nil, actions: declared) do
        {:blocked, reason} -> {:error, :blocked, reason}
        :ok -> dispatch(tool, args)
      end
    end
  end

  defp dispatch(tool, args) do
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
          with {:ok, _} <- Schema.validate_input(args, Map.get(tool.metadata, "schema", %{})),
               {:ok, resolved_args} <- Shem.Secrets.resolve(args),
               {:ok, pool} <-
                 Shem.Lab.PortPool.Supervisor.ensure_started(tool.id, runtime_path, language) do
            PortPool.call(pool, resolved_args)
          end
        end
    end
  end

  # Phase 6: {:beam, _} is reserved for first-party seed modules — compiled into
  # the release and force-loaded at Registry init. Agent/pack Elixir converts to
  # {:port, _} at load; anything else reaching here is refused, never recompiled.
  defp ensure_loaded(%{runtime: {:beam, module}}) do
    if Shem.SeedTools.seed?(module) do
      :ok
    else
      {:error, :runtime, "beam runtime is reserved for first-party seed tools"}
    end
  end
end
