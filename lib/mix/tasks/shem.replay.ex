defmodule Mix.Tasks.Shem.Replay do
  use Mix.Task

  @shortdoc "Deterministic golden-session replay check (exit 0 clean / 1 diverged / 2 error)"
  @moduledoc """
  Re-runs a recorded agent session with the recorded LLM responses (no model
  called) and reports where the replay diverged. Dev-parity twin of
  `shem replay --check <session_id>`.

      mix shem.replay ses_ABCDEF0123456789
  """

  @impl true
  def run([session_id]) do
    case Shem.Replay.Check.cli(session_id) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end

  def run(_) do
    Mix.shell().error("usage: mix shem.replay <session_id>")
    exit({:shutdown, 2})
  end
end
