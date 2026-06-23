defmodule Shem.SeedTools do
  @moduledoc """
  Bundled, always-present deterministic tools. Registered at boot, never
  graduated — they bypass the graduation gate by construction. A user-graduated
  tool with a colliding id overrides the seed (see Registry merge order).
  """
  @modules [
    Shem.SeedTools.DiffText,
    Shem.SeedTools.JsonQuery,
    Shem.SeedTools.GraphifyQuery,
    Shem.SeedTools.ExtractSignatures
  ]

  def modules, do: @modules

  def all, do: Enum.map(@modules, & &1.tool())
end
