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

  test "go: ext/exe/argv/layout" do
    assert Languages.ext("go") == "go"
    assert Languages.exe("go") == "go"
    assert Languages.argv("go", "/x/dir") == ["run", "/x/dir"]
    assert Languages.layout("go") == :dir
    assert Languages.layout("python") == :file
    assert Languages.layout("javascript") == :file
  end

  test "go: dir_files emits tool.go (source), fixed main.go wrapper, go.mod with major.minor directive" do
    files = Languages.dir_files("go", "func run(a map[string]any) any { return a }")
    map = Map.new(files)
    assert map["tool.go"] =~ "func run"
    assert map["main.go"] =~ "bufio.NewScanner(os.Stdin)"
    assert map["main.go"] =~ "json.Marshal(run(args))"
    assert map["go.mod"] =~ ~r/^go 1\.21$/m
    refute map["go.mod"] =~ ~r/go 1\.\d+\.\d+/   # NO patch version
  end
end
