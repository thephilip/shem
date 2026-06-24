defmodule Shem.Lab.PackTest do
  use ExUnit.Case, async: false
  alias Shem.Lab.{Pack, Workspace}

  setup do
    prev = Application.get_env(:shem, :lab_dir)
    lab = Path.join(System.tmp_dir!(), "shem-lab-#{System.unique_integer([:positive])}")
    Application.put_env(:shem, :lab_dir, lab)
    # restore the configured value (config/test.exs sets "tmp/test_lab") — never delete it
    on_exit(fn -> File.rm_rf(lab); Application.put_env(:shem, :lab_dir, prev) end)
    %{lab: lab}
  end

  defp make_pack_repo do
    repo = Path.join(System.tmp_dir!(), "shem-packrepo-#{System.unique_integer([:positive])}")
    File.rm_rf!(repo)
    on_exit(fn -> File.rm_rf(repo) end)
    File.mkdir_p!(Path.join(repo, "tools"))

    good_src = """
    defmodule PackGood do
      def run(%{"x" => x}), do: %{"y" => x + 1}
    end
    """
    good_test = """
    defmodule PackGoodTest do
      def run do
        %{"y" => 2} = PackGood.run(%{"x" => 1})
        :ok
      end
    end
    """
    File.write!(Path.join(repo, "tools/packgood.ex"), good_src)
    File.write!(Path.join(repo, "tools/packgood.json"),
      Jason.encode!(%{"id" => "packgood", "language" => "elixir", "test_source" => good_test}))

    File.write!(Path.join(repo, "pack.json"),
      Jason.encode!(%{"name" => "demo", "version" => "0.1.0", "tools" => ["packgood"]}))

    {_, 0} = System.cmd("git", ["init", "-q", repo])
    {_, 0} = System.cmd("git", ["-C", repo, "add", "."])
    {_, 0} = System.cmd("git", ["-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "x"])
    repo
  end

  defp make_pack_repo_with_bad do
    repo = Path.join(System.tmp_dir!(), "shem-packrepo-#{System.unique_integer([:positive])}")
    File.rm_rf!(repo)
    on_exit(fn -> File.rm_rf(repo) end)
    File.mkdir_p!(Path.join(repo, "tools"))

    bad_src = "defmodule PackBad do\n  def run(_), do: :wrong\nend\n"
    bad_test = "defmodule PackBadTest do\n  def run do\n    %{} = PackBad.run(%{})\n    :ok\n  end\nend\n"
    File.write!(Path.join(repo, "tools/packbad.ex"), bad_src)
    File.write!(Path.join(repo, "tools/packbad.json"),
      Jason.encode!(%{"id" => "packbad", "language" => "elixir", "test_source" => bad_test}))
    File.write!(Path.join(repo, "pack.json"),
      Jason.encode!(%{"name" => "demo", "tools" => ["packbad"]}))

    {_, 0} = System.cmd("git", ["init", "-q", repo])
    {_, 0} = System.cmd("git", ["-C", repo, "add", "."])
    {_, 0} = System.cmd("git", ["-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "x"])
    repo
  end

  test "install gates a tool, writes it, and tags the manifest", %{} do
    repo = make_pack_repo()
    assert {:ok, result} = Pack.install("file://" <> repo)
    assert result.name == "demo"
    assert [id] = result.installed
    assert result.rejected == []

    manifest = Workspace.manifest_path(id) |> File.read!() |> Jason.decode!()
    assert manifest["pack"] == "demo"
    assert is_binary(manifest["sha256"])
  end

  test "a tool that fails its gate is rejected and never written" do
    repo = make_pack_repo_with_bad()
    assert {:ok, result} = Pack.install("file://" <> repo)
    assert result.installed == []
    assert [%{id: "packbad"}] = result.rejected
    # nothing tagged "demo" landed on disk
    tagged =
      Workspace.list_graduated()
      |> Enum.flat_map(fn
        {id, p} -> if match?(%{"pack" => "demo"}, Jason.decode!(File.read!(p))), do: [id], else: []
        _ -> []
      end)
    assert tagged == []
  end

  test "reinstalling a pack replaces its tools instead of duplicating" do
    repo = make_pack_repo()
    {:ok, first} = Pack.install("file://" <> repo)
    assert first.replaced == []

    {:ok, second} = Pack.install("file://" <> repo)
    assert second.replaced != []

    tagged =
      Workspace.list_graduated()
      |> Enum.flat_map(fn
        {id, p} ->
          case Jason.decode!(File.read!(p)) do
            %{"pack" => "demo"} -> [id]
            _ -> []
          end

        _ ->
          []
      end)

    assert length(tagged) == 1
  end

  test "installed manifest carries the pack version" do
    repo = make_pack_repo()
    {:ok, %{installed: [id]}} = Pack.install("file://" <> repo)
    manifest = Workspace.manifest_path(id) |> File.read!() |> Jason.decode!()
    assert manifest["version"] == "0.1.0"
  end

  test "list_packs returns installed packs grouped by name" do
    repo = make_pack_repo()
    {:ok, _} = Pack.install("file://" <> repo)
    packs = Pack.list_packs()
    assert [%{name: "demo", version: "0.1.0", tools: [_]}] = packs
  end

  test "uninstall removes a pack's tools and leaves others alone" do
    other_src = """
    defmodule PackOther do
      def run(%{"x" => x}), do: %{"y" => x * 2}
    end
    """
    other_test = """
    defmodule PackOtherTest do
      def run do
        %{"y" => 4} = PackOther.run(%{"x" => 2})
        :ok
      end
    end
    """
    {:ok, other} = Shem.Lab.GraduationGate.run(other_src, other_test, language: "elixir")

    repo = make_pack_repo()
    {:ok, %{installed: [id]}} = Pack.install("file://" <> repo)
    assert File.exists?(Workspace.manifest_path(id))

    assert {:ok, %{removed: removed}} = Pack.uninstall("demo")
    assert id in removed
    refute File.exists?(Workspace.manifest_path(id))
    assert File.exists?(Workspace.manifest_path(other.id))
  end
end
