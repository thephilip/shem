defmodule Shem.Agent.ToolDispatch do
  alias Shem.Agent.Config
  alias Shem.Lab
  alias Shem.MCP

  @builtins [
    %{
      name: "write_tool",
      description:
        "Graduate a new Elixir tool into the Lab. Args: source (string), test_source (string).",
      source: :builtin
    },
    %{
      name: "run_code",
      description:
        "Run Elixir source defining a module with run/0. Returns the result. Args: source (string), timeout_ms (integer, optional).",
      source: :builtin
    },
    %{
      name: "list_tools",
      description: "List all tools currently available.",
      source: :builtin
    }
  ]

  @spec build_manifest(Config.t()) :: [map()]
  def build_manifest(%Config{tools: allowed_tools}) do
    lab_tools =
      Lab.Registry.all()
      |> Enum.map(fn tool ->
        %{
          name: tool.name,
          description: Map.get(tool.metadata, "description", "graduated tool: #{tool.name}"),
          source: {:lab, tool.id}
        }
      end)

    mcp_tools =
      MCP.Client.connected_servers()
      |> Enum.filter(&(&1.status == :ready))
      |> Enum.flat_map(fn %{name: server} ->
        case MCP.Client.list_tools(server) do
          {:ok, tools} ->
            tools
            |> then(fn ts ->
              if allowed_tools == [],
                do: ts,
                else: Enum.filter(ts, &(&1["name"] in allowed_tools))
            end)
            |> Enum.map(fn t ->
              %{name: t["name"], description: t["description"] || "", source: {:mcp, server}}
            end)

          _ ->
            []
        end
      end)

    @builtins ++ lab_tools ++ mcp_tools
  end

  @spec execute(%{tool: String.t(), args: map()}, [map()]) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(%{tool: "list_tools"}, manifest) do
    lines = Enum.map(manifest, fn %{name: n, description: d} -> "- #{n}: #{d}" end)
    {:ok, "Available tools:\n" <> Enum.join(lines, "\n")}
  end

  def execute(%{tool: name, args: args}, manifest) do
    case find_source(name, manifest) do
      :builtin -> dispatch_builtin(name, args)
      {:lab, id} -> dispatch_lab(id, args)
      {:mcp, server} -> dispatch_mcp(server, name, args)
      nil -> {:error, "unknown tool: #{name}"}
    end
  end

  defp find_source(name, manifest) do
    case Enum.find(manifest, &(&1.name == name)) do
      %{source: source} -> source
      nil -> nil
    end
  end

  defp dispatch_builtin("run_code", args) do
    source = args["source"] || ""
    timeout = args["timeout_ms"] || 5_000

    case Lab.Executor.run(source, fn mod -> mod.run() end, timeout: timeout) do
      {:ok, result} -> {:ok, inspect(result)}
      {:error, :compile, msg} -> {:error, "compile error: #{msg}"}
      {:error, :timeout} -> {:error, "timeout after #{timeout}ms"}
      {:error, :runtime, reason} -> {:error, "runtime error: #{inspect(reason)}"}
    end
  end

  defp dispatch_builtin("write_tool", args) do
    source = args["source"] || ""
    test_source = args["test_source"] || ""

    case Lab.GraduationGate.run(source, test_source) do
      {:ok, tool} -> {:ok, "graduated: #{tool.name}"}
      {:error, :compile, msg} -> {:error, "compile error: #{msg}"}
      {:error, :gate, reason} -> {:error, "test failed: #{inspect(reason)}"}
      {:error, :timeout} -> {:error, "graduation timed out"}
    end
  end

  defp dispatch_builtin(name, _args), do: {:error, "unknown built-in: #{name}"}

  defp dispatch_lab(id, args) do
    case Lab.Registry.lookup(id) do
      {:ok, tool} ->
        with :ok <- ensure_loaded(tool) do
          try do
            {:ok, inspect(tool.module.run(args))}
          rescue
            e -> {:error, "runtime error: #{Exception.message(e)}"}
          end
        end

      {:error, :not_found} ->
        {:error, "tool not found in registry: #{id}"}
    end
  end

  defp ensure_loaded(%{module: module, source: source}) do
    case :code.is_loaded(module) do
      false ->
        try do
          case Code.compile_string(source) do
            compiled when is_list(compiled) ->
              case Enum.find(compiled, fn {mod, _bc} -> mod == module end) do
                {^module, bc} ->
                  case :code.load_binary(module, ~c"nofile", bc) do
                    {:module, _} -> :ok
                    {:error, _} -> {:error, "failed to load #{module}"}
                  end

                nil ->
                  {:error, "failed to compile #{module}"}
              end
          end
        rescue
          e -> {:error, "compile error: #{Exception.message(e)}"}
        end

      _ ->
        :ok
    end
  end

  defp dispatch_mcp(server, name, args) do
    case MCP.Client.call(server, name, args) do
      {:ok, result} -> {:ok, inspect(result)}
      {:error, reason} -> {:error, "mcp error: #{inspect(reason)}"}
    end
  end
end
