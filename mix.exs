defmodule Shem.MixProject do
  use Mix.Project

  def project do
    [
      app: :shem,
      version: "0.1.10",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :os_mon, :mnesia],
      mod: {Shem.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ratatouille, "~> 0.5"},
      {:stream_data, "~> 1.0"},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:yaml_elixir, "~> 2.12"},
      {:horde, "~> 0.9"},
      {:libcluster, "~> 3.3"}
    ]
  end

  defp aliases do
    [
      "deps.get": ["deps.get", &patch_waf/1],
      "deps.compile": [&patch_waf/1, "deps.compile"]
    ]
  end

  defp releases do
    [
      shem: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  # ex_termbox bundles waf 2.0.14 which breaks on Python 3.11+ (removed `imp` module).
  # priv/waf is waf 2.1.4 — copy it into place before every compile.
  defp patch_waf(_) do
    dst = Path.join(~w[deps ex_termbox c_src termbox waf])
    src = Path.join([__DIR__, "priv", "waf"])

    if File.exists?(src) and File.dir?(Path.dirname(dst)) do
      File.cp!(src, dst)
      File.chmod!(dst, 0o755)
    end
  end
end
