defmodule Shem.TUI.CommandDispatch do
  @moduledoc "Parse CLI commands and dispatch to agent, preset, tools, and LLM configuration actions."

  @known_backends ~w[llama_cpp ollama openai anthropic]

  @spec parse(String.t()) ::
          {:start_agent, String.t(), String.t()}
          | {:stop_agent}
          | {:list_agents}
          | {:redteam, String.t()}
          | {:tools}
          | {:trust, String.t()}
          | {:preset_list}
          | {:preset_add, String.t()}
          | {:preset_delete, String.t()}
          | {:preset_switch, String.t()}
          | {:help}
          | {:hire, String.t(), String.t()}
          | {:llm_routes}
          | {:llm_route, [{atom(), :llama_cpp | :ollama | :openai | :anthropic, String.t()}]}
          | {:fence_set, String.t()}
          | {:fence_clear}
          | {:fence_show}
          | {:error, String.t()}
  defp parse_route_pair([key, value]) do
    trimmed_key = String.trim(key)
    trimmed_value = String.trim(value)

    case String.split(trimmed_value, ":", parts: 2) do
      [backend_str, model_string] when model_string != "" ->
        if backend_str in @known_backends do
          {:ok, {String.to_atom(trimmed_key), String.to_atom(backend_str), model_string}}
        else
          valid = Enum.join(@known_backends, ", ")
          {:error, "unknown backend: #{backend_str} — valid: #{valid}"}
        end

      [_backend_str, ""] ->
        # empty model after colon — fall through to existing empty-value error
        {:ok, {String.to_atom(trimmed_key), :llama_cpp, ""}}

      [model_string] ->
        # no colon — backward compat, default to :llama_cpp
        {:ok, {String.to_atom(trimmed_key), :llama_cpp, model_string}}
    end
  end

  def parse(""), do: {:error, "empty input"}

  def parse("/" <> rest) do
    parts = String.split(rest, " ", trim: true)

    case parts do
      ["agent", preset | task_parts] when task_parts != [] ->
        {:start_agent, preset, Enum.join(task_parts, " ")}

      ["agent" | _] ->
        {:error, "usage: /agent <preset> <task>"}

      ["stop"] ->
        {:stop_agent}

      ["agents"] ->
        {:list_agents}

      ["tools" | _] ->
        {:tools}

      ["trust" | name_parts] ->
        name = String.trim(Enum.join(name_parts, " "))
        if name == "" do
          {:error, "usage: /trust <tool_name>"}
        else
          {:trust, name}
        end

      ["redteam" | tool_parts] ->
        name = String.trim(Enum.join(tool_parts, " "))
        if name == "" do
          {:error, "usage: /redteam <tool_name>"}
        else
          {:redteam, name}
        end

      ["help" | _] ->
        {:help}

      ["preset", "list" | _] ->
        {:preset_list}

      ["preset", "add" | name_parts] ->
        name = String.trim(Enum.join(name_parts, " "))
        if name == "", do: {:error, "usage: /preset add <name>"}, else: {:preset_add, name}

      ["preset", "delete" | name_parts] ->
        name = String.trim(Enum.join(name_parts, " "))
        if name == "", do: {:error, "usage: /preset delete <name>"}, else: {:preset_delete, name}

      ["preset", name] when name not in ["list", "add", "delete"] ->
        # guard: ensure new /preset subcommands are added ABOVE this clause
        {:preset_switch, name}

      ["preset" | _] ->
        {:error, "usage: /preset <list|add|delete> ..."}

      ["llm", "routes" | _] ->
        {:llm_routes}

      ["llm", "route" | pair_parts] when pair_parts != [] ->
        raw_pairs =
          pair_parts
          |> Enum.map(&String.split(&1, "=", parts: 2))
          |> Enum.filter(&match?([_, _], &1))
          |> Enum.reject(fn [k, _v] -> String.trim(k) == "" end)

        result =
          Enum.reduce_while(raw_pairs, {:ok, []}, fn pair, {:ok, acc} ->
            case parse_route_pair(pair) do
              {:ok, {_key, _backend, value}} when value == "" ->
                {:halt, {:error, "usage: /llm route <role>=<model> ..."}}

              {:ok, entry} ->
                {:cont, {:ok, [entry | acc]}}

              {:error, msg} ->
                {:halt, {:error, msg}}
            end
          end)

        case result do
          {:ok, []} -> {:error, "usage: /llm route <role>=<model> ..."}
          {:ok, pairs} -> {:llm_route, Enum.reverse(pairs)}
          {:error, msg} -> {:error, msg}
        end

      ["llm", "route"] ->
        {:error, "usage: /llm route <role>=<model> ..."}

      ["llm" | _] ->
        {:error, "unknown /llm subcommand — try: /llm routes, /llm route <role>=<model>"}

      ["hire", name | role_parts] when role_parts != [] ->
        {:hire, name, Enum.join(role_parts, " ")}

      ["hire" | _] ->
        {:error, "usage: /hire <name> <role description>"}

      ["shadow"] ->
        {:shadow_info}

      ["fence"] ->
        {:fence_show}

      ["fence", "clear"] ->
        {:fence_clear}

      ["fence" | path_parts] ->
        {:fence_set, Path.expand(Enum.join(path_parts, " "))}

      _ ->
        {:error, "unknown command: /#{rest}"}
    end
  end

  def parse(text) do
    trimmed = String.trim(text)
    if trimmed == "", do: {:error, "empty input"}, else: {:start_agent, "general", trimmed}
  end

  @doc "Returns all available slash commands with descriptions, for the /help overlay."
  @spec commands() :: [{String.t(), String.t()}]
  def commands do
    [
      {"/help", "Show this command list (searchable)"},
      {"/preset <name>", "Switch preset: general, coder, researcher, writer, security, explorer"},
      {"/preset list", "List all available presets"},
      {"/preset add <name>", "Create a new preset (opens multiline editor)"},
      {"/preset delete <name>", "Delete a preset"},
      {"/hire <name> <role>", "Generate a new AI preset from a role description"},
      {"/agent <preset> <task>", "Start an agent with a preset and task"},
      {"/agents", "List all running agents"},
      {"/stop", "Stop the currently focused agent"},
      {"/redteam <tool>", "Start a red team agent to harden a tool"},
      {"/tools", "List all graduated Lab tools with trust bands"},
      {"/trust <tool>", "Show trust details for a specific tool"},
      {"/llm routes", "Show the current LLM routing table"},
      {"/llm route <role>=<model>", "Set an LLM route (e.g. reasoning=phi4)"},
      {"/shadow", "show shadow agent confidence score and reasoning"},
      {"/fence <path>", "Restrict agent file access to a directory"},
      {"/fence clear", "Remove the active scope fence"},
      {"/fence", "Show the current scope fence"},
    ]
  end
end
