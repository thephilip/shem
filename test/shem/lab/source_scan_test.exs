defmodule Shem.Lab.SourceScanTest do
  use ExUnit.Case, async: true

  alias Shem.Lab.SourceScan

  @pure """
  defmodule PureTool do
    def run(%{"xs" => xs}), do: %{"sum" => Enum.sum(xs)}
  end
  """

  test "pure stdlib tool passes" do
    assert :ok = SourceScan.scan(@pure)
  end

  test "ets and common pure modules pass" do
    src = """
    defmodule EtsTool do
      def run(_) do
        t = :ets.new(:x, [])
        :ets.insert(t, {:k, String.upcase("v")})
        %{"n" => map_size(Map.new(Enum.map([1], &{&1, &1})))}
      end
    end
    """

    assert :ok = SourceScan.scan(src)
  end

  # {description, source_fragment_using_denied_form}
  denied = [
    {"System call", ~s|System.cmd("ls", [])|},
    {"File call", ~s|File.read!("/etc/passwd")|},
    {"erlang os", ~s|:os.cmd(~c"id")|},
    {"open_port", ~s|:erlang.open_port({:spawn, "sh"}, [])|},
    {"Code eval", ~s|Code.eval_string("1")|},
    {"Port", ~s|Port.open({:spawn, "sh"}, [])|},
    {"Node", ~s|Node.spawn(:n@h, fn -> 1 end)|},
    {"Module concat", ~s|Module.concat(Fi, le)|},
    {"rpc", ~s|:rpc.call(:n@h, :os, :cmd, [~c"id"])|},
    {"init", ~s|:init.stop()|},
    {"code server", ~s|:code.load_binary(:m, ~c"f", <<>>)|},
    {"net_kernel", ~s|:net_kernel.stop()|},
    {"erlang file", ~s|:file.read_file("/etc/passwd")|},
    {"mnesia", ~s|:mnesia.dirty_all_keys(:t)|},
    {"apply with denied literal", ~s|apply(File, :read!, ["/x"])|},
    {"spawn MFA with denied literal", ~s|spawn(System, :cmd, ["ls", []])|}
  ]

  for {desc, frag} <- denied do
    test "denies #{desc}" do
      src = """
      defmodule BadTool do
        def run(_), do: #{unquote(frag)}
      end
      """

      assert {:error, "safety scan: " <> _} = SourceScan.scan(src)
    end
  end

  test "denies alias of a denied module" do
    src = """
    defmodule SneakyTool do
      alias File, as: F
      def run(_), do: F.read!("/x")
    end
    """

    assert {:error, "safety scan: " <> _} = SourceScan.scan(src)
  end

  test "denies import of a denied module" do
    src = """
    defmodule SneakyTool2 do
      import System
      def run(_), do: cmd("ls", [])
    end
    """

    assert {:error, "safety scan: " <> _} = SourceScan.scan(src)
  end

  test "denies @on_load and @before_compile and defmacro" do
    for frag <- ["@on_load :boom", "@before_compile Foo", "defmacro boom, do: 1"] do
      src = """
      defmodule AttrTool do
        #{frag}
        def run(_), do: :ok
      end
      """

      assert {:error, "safety scan: " <> _} = SourceScan.scan(src)
    end
  end

  test "unparseable source fails the scan" do
    assert {:error, "safety scan: " <> _} = SourceScan.scan("defmodule Broken do")
  end

  test "error names the line" do
    src = """
    defmodule LineTool do
      def run(_) do
        File.read!("/x")
      end
    end
    """

    assert {:error, msg} = SourceScan.scan(src)
    assert msg =~ "line 3"
  end
end
