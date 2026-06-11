defmodule Shem.CLI.Banner do
  @moduledoc false

  def print do
    if truecolor?() and tty?() do
      path = Application.app_dir(:shem, "priv/banner.ansi")

      if File.exists?(path) do
        path |> File.read!() |> IO.write()
        IO.puts("")
      end
    end
  end

  defp truecolor? do
    System.get_env("COLORTERM") in ["truecolor", "24bit"]
  end

  defp tty? do
    match?({:ok, _}, :io.columns())
  end
end
