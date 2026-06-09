defmodule Shem.Context.ProjectTest do
  use ExUnit.Case, async: true

  alias Shem.Context.Project

  describe "detect/1" do
    test "detects current directory when no path given" do
      ctx = Project.detect()
      assert %Project{} = ctx
      assert is_binary(ctx.path)
      assert is_binary(ctx.name)
      assert is_atom(ctx.type)
      assert is_list(ctx.contents)
      assert is_boolean(ctx.git_repo?)
    end

    test "detects a given path" do
      tmp = System.tmp_dir!()
      ctx = Project.detect(tmp)
      assert ctx.path == tmp
    end

    test "name is the last path component" do
      tmp = System.tmp_dir!()
      ctx = Project.detect(tmp)
      assert ctx.name == Path.basename(tmp)
    end

    test "returns :unknown type for empty directory" do
      tmp = Path.join(System.tmp_dir!(), "shem_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      ctx = Project.detect(tmp)
      assert ctx.type == :unknown
      File.rm_rf!(tmp)
    end

    test "detects elixir project from mix.exs" do
      tmp = Path.join(System.tmp_dir!(), "shem_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "mix.exs"), "")
      ctx = Project.detect(tmp)
      assert ctx.type == :elixir
      File.rm_rf!(tmp)
    end

    test "detects node project from package.json" do
      tmp = Path.join(System.tmp_dir!(), "shem_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "package.json"), "{}")
      ctx = Project.detect(tmp)
      assert ctx.type == :node
      File.rm_rf!(tmp)
    end

    test "detects rust project from Cargo.toml" do
      tmp = Path.join(System.tmp_dir!(), "shem_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "Cargo.toml"), "")
      ctx = Project.detect(tmp)
      assert ctx.type == :rust
      File.rm_rf!(tmp)
    end

    test "detects python project from pyproject.toml" do
      tmp = Path.join(System.tmp_dir!(), "shem_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "pyproject.toml"), "")
      ctx = Project.detect(tmp)
      assert ctx.type == :python
      File.rm_rf!(tmp)
    end

    test "detects python project from requirements.txt" do
      tmp = Path.join(System.tmp_dir!(), "shem_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "requirements.txt"), "")
      ctx = Project.detect(tmp)
      assert ctx.type == :python
      File.rm_rf!(tmp)
    end

    test "detects go project from go.mod" do
      tmp = Path.join(System.tmp_dir!(), "shem_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "go.mod"), "")
      ctx = Project.detect(tmp)
      assert ctx.type == :go
      File.rm_rf!(tmp)
    end

    test "detects ruby project from Gemfile" do
      tmp = Path.join(System.tmp_dir!(), "shem_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "Gemfile"), "")
      ctx = Project.detect(tmp)
      assert ctx.type == :ruby
      File.rm_rf!(tmp)
    end

    test "git_repo? is true when .git exists" do
      tmp = Path.join(System.tmp_dir!(), "shem_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(Path.join(tmp, ".git"))
      ctx = Project.detect(tmp)
      assert ctx.git_repo? == true
      File.rm_rf!(tmp)
    end

    test "git_repo? is false when no .git" do
      tmp = Path.join(System.tmp_dir!(), "shem_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      ctx = Project.detect(tmp)
      assert ctx.git_repo? == false
      File.rm_rf!(tmp)
    end

    test "contents lists top-level entries" do
      tmp = Path.join(System.tmp_dir!(), "shem_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "mix.exs"), "")
      File.mkdir_p!(Path.join(tmp, "lib"))
      ctx = Project.detect(tmp)
      names = Enum.map(ctx.contents, fn {name, _type} -> name end)
      assert "mix.exs" in names
      assert "lib" in names
      File.rm_rf!(tmp)
    end
  end

  describe "to_prompt/1" do
    test "returns a non-empty string" do
      ctx = Project.detect()
      result = Project.to_prompt(ctx)
      assert is_binary(result)
      assert String.length(result) > 0
    end

    test "includes path in output" do
      ctx = Project.detect()
      result = Project.to_prompt(ctx)
      assert String.contains?(result, ctx.path)
    end

    test "includes project type in output" do
      tmp = Path.join(System.tmp_dir!(), "shem_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "mix.exs"), "")
      ctx = Project.detect(tmp)
      result = Project.to_prompt(ctx)
      assert String.contains?(result, "Elixir") or String.contains?(result, "elixir")
      File.rm_rf!(tmp)
    end

    test "mentions git repo when git_repo? is true" do
      tmp = Path.join(System.tmp_dir!(), "shem_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(Path.join(tmp, ".git"))
      ctx = Project.detect(tmp)
      result = Project.to_prompt(ctx)
      assert String.contains?(result, "git")
      File.rm_rf!(tmp)
    end
  end
end
