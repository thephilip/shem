defmodule Shem.TUI.CommandDispatch do
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
          | {:llm_routes}
          | {:llm_route, [{atom(), :llama_cpp | :ollama, String.t()}]}
          | {:error, String.t()}
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

      ["preset", "list" | _] ->
        {:preset_list}

      ["preset", "add" | name_parts] ->
        name = String.trim(Enum.join(name_parts, " "))
        if name == "", do: {:error, "usage: /preset add <name>"}, else: {:preset_add, name}

      ["preset", "delete" | name_parts] ->
        name = String.trim(Enum.join(name_parts, " "))
        if name == "", do: {:error, "usage: /preset delete <name>"}, else: {:preset_delete, name}

      ["preset" | _] ->
        {:error, "usage: /preset <list|add|delete> ..."}

      ["llm", "routes" | _] ->
        {:llm_routes}

      ["llm", "route" | pair_parts] when pair_parts != [] ->
        pairs =
          pair_parts
          |> Enum.map(&String.split(&1, "=", parts: 2))
          |> Enum.filter(&match?([_, _], &1))
          |> Enum.reject(fn [k, v] -> String.trim(k) == "" or String.trim(v) == "" end)
          |> Enum.map(fn [k, v] -> {String.to_atom(String.trim(k)), :llama_cpp, String.trim(v)} end)

        if pairs == [] do
          {:error, "usage: /llm route <role>=<model> ..."}
        else
          {:llm_route, pairs}
        end

      ["llm", "route"] ->
        {:error, "usage: /llm route <role>=<model> ..."}

      ["llm" | _] ->
        {:error, "unknown /llm subcommand — try: /llm routes, /llm route <role>=<model>"}

      _ ->
        {:error, "unknown command: /#{rest}"}
    end
  end

  def parse(text) do
    trimmed = String.trim(text)
    if trimmed == "", do: {:error, "empty input"}, else: {:start_agent, "general", trimmed}
  end
end
