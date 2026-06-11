defmodule Shem.Agent.ToolDispatch do
  alias Shem.Agent
  alias Shem.Agent.Config
  alias Shem.Lab
  alias Shem.Memory
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
    },
    %{
      name: "remember",
      description: "Store a value under a key in persistent memory. Use namespaced keys like \"coding/style\" or \"user/name\" to avoid collisions.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{
          "key"   => %{"type" => "string"},
          "value" => %{"type" => "string"}
        },
        required: ["key", "value"]
      }
    },
    %{
      name: "recall",
      description: "Retrieve a previously stored memory by key. Returns the value or a miss message.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{"key" => %{"type" => "string"}},
        required: ["key"]
      }
    },
    %{
      name: "forget",
      description: "Delete a memory entry by key.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{"key" => %{"type" => "string"}},
        required: ["key"]
      }
    },
    %{
      name: "list_memories",
      description: "List all stored memories, optionally filtered by key prefix (e.g. \"coding/\"). Returns sorted key = value lines.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{"prefix" => %{"type" => "string"}},
        required: []
      }
    },
    %{
      name: "spawn_agent",
      description: "Delegate a task to a sub-agent. Specify the task and optionally a preset name (default: general). Returns the sub-agent's final answer.",
      source: :builtin,
      trust: :builtin,
      schema: %{
        type: "object",
        properties: %{
          "task"   => %{"type" => "string"},
          "preset" => %{"type" => "string"}
        },
        required: ["task"]
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

  @spec execute(%{name: String.t(), args: map()}, [map()], keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(call, manifest, opts \\ [])

  def execute(%{name: "list_tools"}, manifest, _opts) do
    lines = Enum.map(manifest, fn %{name: n, description: d} -> "- #{n}: #{d}" end)
    {:ok, "Available tools:\n" <> Enum.join(lines, "\n")}
  end

  def execute(%{name: name, args: args}, manifest, opts) do
    case Enum.find(manifest, &(&1.name == name)) do
      nil ->
        {:error, "unknown tool: #{name}"}

      %{source: :builtin} ->
        with :ok <- Shem.Guardrails.check_fence(opts[:fence], name, args, backend: opts[:backend]) do
          dispatch_builtin(name, args)
        else
          {:blocked, reason} -> {:error, reason}
        end

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

  defp dispatch_builtin("remember", args) do
    key = args["key"]
    value = args["value"]

    if is_binary(key) and is_binary(value) do
      Memory.Store.put(key, value)
      {:ok, "stored: #{key}"}
    else
      {:error, "remember requires key and value"}
    end
  end

  defp dispatch_builtin("recall", args) do
    key = args["key"]

    if is_binary(key) do
      case Memory.Store.get(key) do
        {:ok, value} -> {:ok, value}
        {:error, :not_found} -> {:ok, "no memory at key: #{key}"}
      end
    else
      {:error, "recall requires key"}
    end
  end

  defp dispatch_builtin("forget", args) do
    key = args["key"]

    if is_binary(key) do
      case Memory.Store.delete(key) do
        :ok -> {:ok, "forgotten: #{key}"}
        {:error, :not_found} -> {:ok, "no memory at key: #{key}"}
      end
    else
      {:error, "forget requires key"}
    end
  end

  defp dispatch_builtin("list_memories", args) do
    prefix = args["prefix"] || ""

    case Memory.Store.all(prefix) do
      [] ->
        {:ok, "no memories found"}

      entries ->
        lines = Enum.map(entries, fn {k, v} -> "#{k} = #{v}" end)
        {:ok, Enum.join(lines, "\n")}
    end
  end

  defp dispatch_builtin("spawn_agent", args) do
    task = args["task"]
    preset = args["preset"] || "general"
    depth = Process.get(:spawn_agent_depth, 0)
    max_depth = Application.get_env(:shem, :spawn_agent_max_depth, 3)
    timeout = Application.get_env(:shem, :spawn_agent_timeout_ms, 300_000)

    cond do
      not is_binary(task) ->
        {:error, "spawn_agent requires task"}

      depth >= max_depth ->
        {:error, "spawn_agent depth limit reached (#{max_depth})"}

      true ->
        Process.put(:spawn_agent_depth, depth + 1)

        result =
          try do
            case Agent.start_with_preset(preset, task, spawn_depth: depth + 1) do
              {:ok, name, _sid} ->
                case Agent.await_result(name, timeout) do
                  {:ok, answer} -> {:ok, answer}
                  {:error, reason} -> {:error, "sub-agent failed: #{inspect(reason)}"}
                end

              {:error, reason} ->
                {:error, "sub-agent failed: #{inspect(reason)}"}
            end
          after
            Process.put(:spawn_agent_depth, depth)
          end

        result
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

  defp score_to_band(score) when score >= 0.8, do: :high
  defp score_to_band(score) when score >= 0.5, do: :medium
  defp score_to_band(_score), do: :low
end
