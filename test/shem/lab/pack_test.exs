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
end
