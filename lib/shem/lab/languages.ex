defmodule Shem.Lab.Languages do
  @moduledoc """
  Per-language details for `:port`-runtime tools (Python, JavaScript).
  4th language = add clauses here. `"elixir"` is the `{:beam, _}` path, not here.
  """

  def ext("python"), do: "py"
  def ext("javascript"), do: "ts"

  def exe("python"), do: "python3"
  def exe("javascript"), do: "deno"

  def argv("python", script), do: [script]
  def argv("javascript", script), do: ["run", script]

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
