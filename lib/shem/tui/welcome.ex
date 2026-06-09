defmodule Shem.TUI.Welcome do
  @moduledoc "First-launch detection and welcome marker management."

  @marker_path Path.join([
    System.get_env("HOME", "/tmp"),
    ".config", "shem", "welcomed"
  ])

  @spec first_launch?() :: boolean()
  def first_launch?, do: not File.exists?(@marker_path)

  @spec mark_welcomed() :: :ok
  def mark_welcomed do
    File.mkdir_p!(Path.dirname(@marker_path))
    File.write!(@marker_path, "")
    :ok
  end

  @spec marker_path() :: String.t()
  def marker_path, do: @marker_path
end
