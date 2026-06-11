defmodule Shem.GuardrailsTest do
  use ExUnit.Case, async: true

  alias Shem.Guardrails
  alias Shem.Lab.Executor.Backend

  describe "check_fence/4" do
    test "fence nil always returns :ok" do
      assert :ok = Guardrails.check_fence(nil, "read_file", %{"path" => "/anywhere"}, [])
    end

    test "path inside fence returns :ok" do
      fence = System.tmp_dir!()
      path = Path.join(fence, "subdir/file.txt")
      assert :ok = Guardrails.check_fence(fence, "read_file", %{"path" => path}, [])
    end

    test "path outside fence returns {:blocked, _}" do
      fence = Path.join(System.tmp_dir!(), "project")
      path = "/etc/passwd"
      assert {:blocked, reason} = Guardrails.check_fence(fence, "read_file", %{"path" => path}, [])
      assert reason =~ "scope fence"
    end

    test "list_dir path inside fence returns :ok" do
      fence = System.tmp_dir!()
      path = Path.join(fence, "subdir")
      assert :ok = Guardrails.check_fence(fence, "list_dir", %{"path" => path}, [])
    end

    test "list_dir path outside fence returns {:blocked, _}" do
      fence = Path.join(System.tmp_dir!(), "project")
      assert {:blocked, _} = Guardrails.check_fence(fence, "list_dir", %{"path" => "/etc"}, [])
    end

    test "relative path is expanded before check" do
      fence = File.cwd!()
      assert :ok = Guardrails.check_fence(fence, "read_file", %{"path" => "lib/shem.ex"}, [])
    end

    test "relative path outside fence is blocked" do
      fence = Path.join(File.cwd!(), "lib")
      assert {:blocked, _} = Guardrails.check_fence(fence, "read_file", %{"path" => "test/test_helper.exs"}, [])
    end

    test "shell with container backend returns :ok regardless of fence" do
      fence = Path.join(System.tmp_dir!(), "project")
      assert :ok = Guardrails.check_fence(fence, "shell", %{"cmd" => "rm -rf /"}, [backend: Backend.Container])
    end

    test "shell with local backend returns {:blocked, _} when fence is active" do
      fence = System.tmp_dir!()
      assert {:blocked, _} = Guardrails.check_fence(fence, "shell", %{"cmd" => "ls"}, [backend: Backend.Local])
    end

    test "other tools (write_file, run_code) are not fenced" do
      fence = Path.join(System.tmp_dir!(), "project")
      assert :ok = Guardrails.check_fence(fence, "write_file", %{"path" => "/etc/passwd"}, [])
      assert :ok = Guardrails.check_fence(fence, "run_code", %{"source" => "IO.puts(:hi)"}, [])
    end

    test "symlink path is checked literally, not resolved" do
      fence = Path.join(System.tmp_dir!(), "project")
      inside_path = Path.join(fence, "link_to_etc")
      assert :ok = Guardrails.check_fence(fence, "read_file", %{"path" => inside_path}, [])
    end

    test "sibling directory with same prefix is blocked" do
      fence = Path.join(System.tmp_dir!(), "project")
      sibling = Path.join(System.tmp_dir!(), "project2/file.txt")
      assert {:blocked, _} = Guardrails.check_fence(fence, "read_file", %{"path" => sibling}, [])
    end
  end

  describe "kill_session/1" do
    test "returns {:error, :not_found} for unknown agent" do
      assert {:error, :not_found} = Guardrails.kill_session("nonexistent_agent_xyz")
    end
  end
end
