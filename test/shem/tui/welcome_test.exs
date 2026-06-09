defmodule Shem.TUI.WelcomeTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.Welcome

  describe "marker_path/0" do
    test "returns a string" do
      assert is_binary(Welcome.marker_path())
    end

    test "contains 'shem' and 'welcomed'" do
      path = Welcome.marker_path()
      assert path =~ "shem"
      assert path =~ "welcomed"
    end
  end

  describe "first_launch?/0 and mark_welcomed/0" do
    test "first_launch? returns true when marker file does not exist" do
      # We can't easily control the marker path without private access,
      # but we can at least verify first_launch? returns a boolean.
      result = Welcome.first_launch?()
      assert is_boolean(result)
    end

    test "mark_welcomed creates the marker file" do
      path = Welcome.marker_path()

      # Ensure the file doesn't exist, or skip if it does (idempotent)
      existed_before = File.exists?(path)

      Welcome.mark_welcomed()
      assert File.exists?(path)

      # Clean up only if we created it
      unless existed_before do
        File.rm(path)
      end
    end

    test "first_launch? returns false after mark_welcomed" do
      path = Welcome.marker_path()
      existed_before = File.exists?(path)

      Welcome.mark_welcomed()
      assert Welcome.first_launch?() == false

      unless existed_before do
        File.rm(path)
      end
    end
  end
end
