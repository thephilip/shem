defmodule Shem.Lab.GraduationGate.Common do
  @moduledoc "Shared register-and-seed tail for the per-language graduation gates."

  alias Shem.Lab.{Registry, Workspace}
  alias Shem.Tool

  @no_property_seed 0.5

  @spec register_and_seed(Tool.t(), boolean()) :: {:ok, Tool.t()}
  def register_and_seed(%Tool{} = tool, seed? \\ true) do
    :ok = Workspace.graduate(tool)
    :ok = Registry.register(tool)
    # Property tools earn trust by passing their properties; others get a
    # lightweight single-turn review refining the default seed. Full red-team
    # loop stays opt-in via Shem.Adversarial.start_hardening/1.
    if seed?, do: seed_trust(tool.id, hardening_score(tool))
    {:ok, tool}
  end

  defp hardening_score(tool) do
    case Shem.Lab.GraduationGate.Hardening.check(tool) do
      {:ok, score} -> score
      :skip -> @no_property_seed
    end
  end

  defp seed_trust(tool_id, score) do
    Shem.Trust.Store.seed(tool_id, score)
  catch
    :exit, _ -> :ok
  end
end
