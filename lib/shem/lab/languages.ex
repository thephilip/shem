defmodule Shem.Lab.Languages do
  @moduledoc """
  Per-language details for `:port`-runtime tools (Python, JavaScript).
  4th language = add clauses here. `"elixir"` is the `{:beam, _}` path, not here.
  """

  def ext("python"), do: "py"
  def ext("javascript"), do: "ts"
  def ext("go"), do: "go"

  def exe("python"), do: "python3"
  def exe("javascript"), do: "deno"
  def exe("go"), do: "go"

  def argv("python", script), do: [script]
  def argv("javascript", script), do: ["run", script]
  def argv("go", dir), do: ["run", dir]

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
