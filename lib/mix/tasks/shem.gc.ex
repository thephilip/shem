defmodule Mix.Tasks.Shem.Gc do
  use Mix.Task

  @shortdoc "Prune a session's old events into a rollup digest"
  @moduledoc """
  Dev twin of `shem gc <session_id> [--keep N]`.

      mix shem.gc ses_ABCDEF0123456789 [--keep N]
  """

  @impl true
  def run([session_id | rest]) do
    keep =
      case rest do
        ["--keep", n] -> String.to_integer(n)
        [] -> nil
        _ -> Mix.shell().error("usage: mix shem.gc <session_id> [--keep N]") && exit({:shutdown, 2})
      end

    case Shem.GC.cli(session_id, keep) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end

  def run(_) do
    Mix.shell().error("usage: mix shem.gc <session_id> [--keep N]")
    exit({:shutdown, 2})
  end
end
