defmodule Shem.Lab.Languages do
  @moduledoc """
  Per-language details for `:port`-runtime tools (Python, JavaScript).
  Elixir joined in Phase 6 (parity sandbox).
  """

  def ext("python"), do: "py"
  def ext("javascript"), do: "ts"
  def ext("go"), do: "go"
  def ext("elixir"), do: "exs"

  def exe("python"), do: "python3"
  def exe("javascript"), do: "deno"
  def exe("go"), do: "go"
  def exe("elixir"), do: "elixir"

  def argv("python", script), do: [script]
  def argv("javascript", script), do: ["run", script]
  def argv("go", dir), do: ["run", dir]
  def argv("elixir", script), do: [script]

  @doc """
  How to launch `elixir` on the host. Returns `{executable, prefix_argv}` —
  append the script path (and its args).

  Inside a release it uses the release's OWN bundled ERTS + Elixir ebins
  (`erl -boot start_clean -pa … -s elixir start_cli -extra`), so the portable
  tarball runs/graduates Elixir tools with neither a container runtime nor a
  separate Elixir install — and it stays self-consistent with the release's
  ERTS env instead of misbooting a mismatched system `elixir`. In a dev/source
  run (no bundled Elixir under the code root) it uses system `elixir` on PATH.
  Either way it launches a *fresh* BEAM, never the host BEAM.
  """
  @spec host_elixir() :: {String.t(), [String.t()]}
  def host_elixir do
    case bundled_elixir() do
      {_erl, _prefix} = bundled -> bundled
      :none -> {System.find_executable("elixir") || "elixir", []}
    end
  end

  defp bundled_elixir do
    root = to_string(:code.root_dir())

    with [erl | _] <- Path.wildcard(Path.join(root, "erts-*/bin/erl")),
         [boot | _] <- Path.wildcard(Path.join(root, "releases/*/start_clean.boot")),
         [_ | _] <- Path.wildcard(Path.join(root, "lib/elixir-*/ebin")) do
      # Only the Elixir stdlib apps — NOT Shem or its deps — so agent source in
      # the host-fallback tier runs against a clean Elixir, same as `elixir X.exs`.
      pa =
        ~w(elixir eex ex_unit iex logger mix)
        |> Enum.flat_map(fn app ->
          root |> Path.join("lib/#{app}-*/ebin") |> Path.wildcard() |> Enum.take(1)
        end)
        |> Enum.flat_map(&["-pa", &1])

      prefix =
        [
          "-boot",
          String.trim_trailing(boot, ".boot"),
          "-boot_var",
          "RELEASE_LIB",
          Path.join(root, "lib"),
          # force UTF-8 filename encoding — start_clean drops the locale erl sets
          "+fnu"
        ] ++ pa ++ ["-noshell", "-s", "elixir", "start_cli", "-extra"]

      {erl, prefix}
    else
      # Not a release (dev/source run) — defer to system elixir.
      _ -> :none
    end
  end

  # Runtime artifact layout: single file (python/js) vs a directory package (go).
  def layout("go"), do: :dir
  def layout(_), do: :file

  # Files written into a :dir runtime artifact. `main.go` is fixed — `run` is
  # resolved at compile time from the sibling tool.go in the same package.
  def dir_files("go", source) do
    [
      {"tool.go", source},
      {"main.go", go_main_wrapper()},
      {"go.mod", "module shemtool\n\ngo 1.21\n"}
    ]
  end

  defp go_main_wrapper do
    """
    package main

    import (
    \t"bufio"
    \t"encoding/json"
    \t"fmt"
    \t"os"
    )

    func main() {
    \tsc := bufio.NewScanner(os.Stdin)
    \tfor sc.Scan() {
    \t\tif len(sc.Bytes()) == 0 {
    \t\t\tcontinue
    \t\t}
    \t\tvar args map[string]any
    \t\tif err := json.Unmarshal(sc.Bytes(), &args); err != nil {
    \t\t\tb, _ := json.Marshal(map[string]any{"__error__": err.Error()})
    \t\t\tfmt.Println(string(b))
    \t\t\tcontinue
    \t\t}
    \t\tb, _ := json.Marshal(run(args))
    \t\tfmt.Println(string(b))
    \t}
    }
    """
  end

  def wrapper("python", source) do
    """
    import sys
    import json

    #{source}

    if __name__ == "__main__":
        for line in sys.stdin:
            line = line.strip()
            if line:
                try:
                    args = json.loads(line)
                    result = run(args)
                    print(json.dumps(result), flush=True)
                except Exception as e:
                    print(json.dumps({"__error__": str(e)}), flush=True)
    """
  end

  # Warm BEAM kept alive across newline-delimited JSON requests (Python-runner
  # contract: `__error__` key on failure). Stdlib JSON only — no deps in-container.
  def wrapper("elixir", source) do
    [_, mod] = Regex.run(~r/defmodule\s+(\S+)\s+do/, source)

    """
    #{source}

    defmodule ShemRunner do
      def loop(mod) do
        case IO.read(:stdio, :line) do
          line when is_binary(line) ->
            line = String.trim(line)

            if line != "" do
              out =
                try do
                  result = mod.run(JSON.decode!(line))

                  try do
                    JSON.encode!(result)
                  rescue
                    # non-JSON-able term (tuple, pid, ...) -> ship its inspect form
                    _ -> JSON.encode!(inspect(result))
                  end
                rescue
                  e -> JSON.encode!(%{"__error__" => Exception.message(e)})
                end

              IO.puts(out)
            end

            loop(mod)

          _ ->
            :ok
        end
      end
    end

    ShemRunner.loop(#{mod})
    """
  end

  # Deno keeps the process alive across many newline-delimited requests, so we must
  # stream and split on "\\n" — NOT read stdin to EOF. `await run` supports async tools.
  def wrapper("javascript", source) do
    """
    #{source}

    const dec = new TextDecoder(); let buf = "";
    for await (const chunk of Deno.stdin.readable) {
      buf += dec.decode(chunk); let i;
      while ((i = buf.indexOf("\\n")) >= 0) {
        const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
        if (line) try { console.log(JSON.stringify(await run(JSON.parse(line)))); }
                  catch (e) { console.log(JSON.stringify({ __error__: String(e) })); }
      }
    }
    """
  end
end
