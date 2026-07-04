defmodule Mix.Tasks.Shem.Attest do
  use Mix.Task

  @shortdoc "Export a session as an offline-verifiable attest bundle"
  @moduledoc """
  Writes a self-verifying bundle for a recorded session. Dev twin of
  `shem attest <session_id>`.

      mix shem.attest ses_ABCDEF0123456789 [out_dir]
  """

  @impl true
  def run([session_id | rest]) do
    out = List.first(rest) || File.cwd!()

    case Shem.Attest.cli(session_id, out) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end

  def run(_) do
    Mix.shell().error("usage: mix shem.attest <session_id> [out_dir]")
    exit({:shutdown, 2})
  end
end
