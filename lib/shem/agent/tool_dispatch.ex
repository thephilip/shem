defmodule Shem.Agent.ToolDispatch do
  alias Shem.Agent.Config
  alias Shem.Lab
  alias Shem.MCP
  alias Shem.Trust

  @builtins [
    %{
      name: "list_tools",
      description: "List all tools currently available.",
      source: :builtin,
      trust: :builtin,
      schema: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "run_code",
      description: "Run Elixir source defining a module with run/0. Returns the result.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{
          "source"     => %{"type" => "string"},
          "timeout_ms" => %{"type" => "integer"}
        },
        required: ["source"]
      }
    },
    %{
      name: "write_tool",
      description: "Graduate a new Elixir tool into the Lab.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{
          "source"      => %{"type" => "string"},
          "test_source" => %{"type" => "string"}
        },
        required: ["source", "test_source"]
      }
    },
    %{
      name: "read_file",
      description: "Read a file and return its contents.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{"path" => %{"type" => "string"}},
        required: ["path"]
      }
    },
    %{
      name: "write_file",
      description: "Write content to a file.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{
          "path"    => %{"type" => "string"},
          "content" => %{"type" => "string"}
        },
        required: ["path", "content"]
      }
    },
    %{
      name: "list_dir",
      description: "List entries in a directory.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{"path" => %{"type" => "string"}},
        required: ["path"]
      }
    },
    %{
      name: "shell",
      description: "Run a shell command and return stdout. Args: cmd (string), timeout_ms (integer, optional, default 10000). NOTE: runs locally until Phase 9b K8s executor.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{
          "cmd"        => %{"type" => "string"},
          "timeout_ms" => %{"type" => "integer"}
        },
        required: ["cmd"]
      }
    }
  ]

  @spec build_manifest(Config.t()) :: [map()]
  def build_manifest(%Config{tools: allowed_tools}) do
    builtins =
      @builtins
      |> then(fn bs ->
        if allowed_tools == [],
          do: bs,
          else: Enum.filter(bs, &(&1.name in allowed_tools))
      end)
      # always inject list_tools — agents need it to discover what tools they have
      |> then(fn bs ->
        if Enum.any?(bs, &(&1.name == "list_tools")),
          do: bs,
          else: [Enum.find(@builtins, &(&1.name == "list_tools")) | bs]
      end)

    lab_tools =
      Lab.Registry.all()
      |> then(fn tools ->
        if allowed_tools == [],
          do: tools,
          else: Enum.filter(tools, &(&1.name in allowed_tools))
      end)
      |> Enum.map(fn tool ->
        trust =
          case Trust.Store.score(tool.id) do
            {:ok, score} -> score_to_band(score)
            {:error, :unrated} -> :unrated
          end

        %{
          name: tool.name,
          description: Map.get(tool.metadata, "description", "graduated tool: #{tool.name}"),
          source: {:lab, tool.id},
          trust: trust,
          schema: %{type: "object", properties: %{}, required: []}
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
              %{name: t["name"], description: t["description"] || "", source: {:mcp, server}, trust: :external, schema: %{type: "object", properties: %{}, required: []}}
            end)

          _ ->
            []
        end
      end)

    builtins ++ lab_tools ++ mcp_tools
  end

  @spec execute(%{name: String.t(), args: map()}, [map()]) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(%{name: "list_tools"}, manifest) do
    lines = Enum.map(manifest, fn %{name: n, description: d} -> "- #{n}: #{d}" end)
    {:ok, "Available tools:\n" <> Enum.join(lines, "\n")}
  end

  def execute(%{name: name, args: args}, manifest) do
    case Enum.find(manifest, &(&1.name == name)) do
      nil ->
        {:error, "unknown tool: #{name}"}

      %{source: :builtin} ->
        dispatch_builtin(name, args)

      %{source: {:mcp, server}} ->
        dispatch_mcp(server, name, args)

      %{source: {:lab, id}, trust: trust} ->
        if gate_blocks?(trust),
          do: {:error, "tool blocked (trust: #{trust})"},
          else: dispatch_lab(id, args)
    end
  end

  defp gate_blocks?(:low), do: Application.get_env(:shem, :trust_gate_enabled, true)
  defp gate_blocks?(_), do: false

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

  defp dispatch_builtin("read_file", args) do
    path = args["path"] || ""

    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "read_file failed: #{:file.format_error(reason)}"}
    end
  end

  defp dispatch_builtin("write_file", args) do
    path = args["path"] || ""
    content = args["content"] || ""

    case File.write(path, content) do
      :ok -> {:ok, "written #{byte_size(content)} bytes to #{path}"}
      {:error, reason} -> {:error, "write_file failed: #{:file.format_error(reason)}"}
    end
  end

  defp dispatch_builtin("list_dir", args) do
    path = args["path"] || ""

    case File.ls(path) do
      {:ok, entries} -> {:ok, Enum.join(entries, "\n")}
      {:error, reason} -> {:error, "list_dir failed: #{:file.format_error(reason)}"}
    end
  end

  defp dispatch_builtin("shell", args) do
    cmd = args["cmd"] || ""
    timeout = args["timeout_ms"] || 10_000
    Lab.Executor.run_shell(cmd, timeout)
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

  defp score_to_band(score) when score >= 0.8, do: :high
  defp score_to_band(score) when score >= 0.5, do: :medium
  defp score_to_band(_score), do: :low
end
