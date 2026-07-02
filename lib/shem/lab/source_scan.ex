defmodule Shem.Lab.SourceScan do
  @moduledoc """
  Static AST deny-scan for Elixir tool source. Stopgap bar-raiser until
  ROADMAP Phase 5 gives Elixir tools real process isolation: graduated
  Elixir tools are pure compute — no file/system/network/code-loading.

  KNOWN LIMIT: a static scan cannot catch fully dynamic dispatch (modules
  built from runtime strings). `Module` is denied, which blocks the literal
  `Module.concat` evasion; deeper evasion is accepted risk until Phase 5.
  """

  @denied_elixir [:System, :File, :Port, :Code, :Node, :Module]
  @denied_erlang [:os, :init, :code, :rpc, :net_kernel, :file, :mnesia]
  @denied_erlang_bifs [:open_port, :halt, :binary_to_term, :spawn, :spawn_link]
  @denied_attrs [:on_load, :before_compile]

  @spec scan(String.t()) :: :ok | {:error, String.t()}
  def scan(source) do
    case Code.string_to_quoted(source, columns: false) do
      {:ok, ast} ->
        {_, violation} = Macro.prewalk(ast, nil, &check/2)

        case violation do
          nil -> :ok
          {desc, line} -> {:error, "safety scan: #{desc} at line #{line}"}
        end

      {:error, {meta, msg, token}} ->
        line = if is_list(meta), do: Keyword.get(meta, :line, "?"), else: meta

        {:error,
         "safety scan: unparseable source (#{inspect(msg)}#{inspect(token)}) at line #{line}"}
    end
  end

  # keep first violation only
  defp check(node, {_, _} = found), do: {node, found}

  # Elixir remote call: File.read!(...) / aliased module resolved at AST level
  defp check({{:., meta, [{:__aliases__, _, [mod | _]}, fun]}, _, _} = node, nil)
       when mod in @denied_elixir do
    {node, {"#{mod}.#{fun}", line(meta)}}
  end

  # Erlang remote call: :os.cmd(...)
  defp check({{:., meta, [mod, fun]}, _, _} = node, nil) when mod in @denied_erlang do
    {node, {":#{mod}.#{fun}", line(meta)}}
  end

  # :erlang dangerous subset
  defp check({{:., meta, [:erlang, fun]}, _, _} = node, nil) when fun in @denied_erlang_bifs do
    {node, {":erlang.#{fun}", line(meta)}}
  end

  # alias/import/require of a denied module (with or without options)
  defp check({directive, meta, [{:__aliases__, _, [mod | _]} | _]} = node, nil)
       when directive in [:alias, :import, :require] and mod in @denied_elixir do
    {node, {"#{directive} #{mod}", line(meta)}}
  end

  defp check({directive, meta, [mod | _]} = node, nil)
       when directive in [:alias, :import, :require] and mod in @denied_erlang do
    {node, {"#{directive} :#{mod}", line(meta)}}
  end

  # apply/spawn/spawn_link/spawn_monitor with a denied literal module
  defp check({fun, meta, [{:__aliases__, _, [mod | _]} | _]} = node, nil)
       when fun in [:apply, :spawn, :spawn_link, :spawn_monitor] and mod in @denied_elixir do
    {node, {"#{fun}(#{mod}, ...)", line(meta)}}
  end

  defp check({fun, meta, [mod | _]} = node, nil)
       when fun in [:apply, :spawn, :spawn_link, :spawn_monitor] and
              (mod in @denied_erlang or mod == :erlang) do
    {node, {"#{fun}(:#{mod}, ...)", line(meta)}}
  end

  # @on_load / @before_compile
  defp check({:@, meta, [{attr, _, _}]} = node, nil) when attr in @denied_attrs do
    {node, {"@#{attr}", line(meta)}}
  end

  # tool modules have no business defining macros
  defp check({:defmacro, meta, _} = node, nil), do: {node, {"defmacro", line(meta)}}
  defp check({:defmacrop, meta, _} = node, nil), do: {node, {"defmacrop", line(meta)}}

  defp check(node, nil), do: {node, nil}

  defp line(meta), do: Keyword.get(meta, :line, "?")
end
