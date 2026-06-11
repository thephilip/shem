defmodule Shem.TUI.Welcome do
  @moduledoc "First-launch detection and welcome marker management."

  @spec marker_path() :: String.t()
  def marker_path, do: Path.join([System.user_home!(), ".config", "shem", "welcomed"])

  @spec first_launch?() :: boolean()
  def first_launch?, do: not File.exists?(marker_path())

  @spec mark_welcomed() :: :ok
  def mark_welcomed do
    path = marker_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    :ok
  end
end
