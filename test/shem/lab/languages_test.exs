defmodule Shem.Lab.LanguagesTest do
  use ExUnit.Case, async: true
  alias Shem.Lab.Languages

  test "ext/exe/argv per language" do
    assert Languages.ext("python") == "py"
    assert Languages.ext("javascript") == "ts"
    assert Languages.exe("javascript") == "deno"
    assert Languages.argv("python", "/x/r.py") == ["/x/r.py"]
    assert Languages.argv("javascript", "/x/r.ts") == ["run", "/x/r.ts"]
  end

  test "js wrapper streams line-delimited stdin and defines no import" do
    w = Languages.wrapper("javascript", "function run(a){return a}")
    assert w =~ "Deno.stdin.readable"
    assert w =~ "function run(a){return a}"
    assert w =~ "__error__"
    refute w =~ "readable).text()"   # the read-to-EOF trap — must NOT be used
  end
end
