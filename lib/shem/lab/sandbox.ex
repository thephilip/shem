defmodule Shem.Lab.Sandbox do
  @moduledoc """
  Decides how a PortPool worker is spawned: in a container (`podman run -i …`)
  when a container runtime is available, or directly on the host (today's
  behavior) as a fallback. Pure spawn-spec building plus best-effort,
  label-scoped container cleanup. See
  docs/superpowers/specs/2026-06-26-container-phase-b-design.md.
  """
  require Logger
  alias Shem.Lab.Languages

  @spec image(String.t()) :: String.t()
  def image("python"),
    do: Application.get_env(:shem, :executor_image_python, "python:3.12-slim")

  def image("javascript"),
    do: Application.get_env(:shem, :executor_image_js, "docker.io/denoland/deno:alpine")

  def image("go"),
    do: Application.get_env(:shem, :executor_image_go, "docker.io/library/golang:alpine")

  def image("elixir"),
    do: Application.get_env(:shem, :executor_image_elixir, "docker.io/library/elixir:1.19-alpine")

  @spec spawn_spec(String.t() | nil, map()) :: {String.t(), [String.t()], keyword()}
  def spawn_spec(nil, %{language: lang, runtime_path: path, host_exe: exe}) do
    port_opts =
      case Languages.layout(lang) do
        :dir -> [cd: path]
        :file -> []
      end

    {exe, Languages.argv(lang, path), port_opts}
  end

  def spawn_spec(runtime_bin, %{language: lang, runtime_path: path, tool_id: id} = spec)
      when is_binary(runtime_bin) do
    {runtime_bin, container_argv(lang, path, id, Map.get(spec, :granted) || %{}), []}
  end

  @spec requires_container?(map() | nil) :: boolean()
  def requires_container?(granted), do: (granted || %{}) != %{}

  defp container_argv(lang, runtime_path, tool_id, granted) do
    name = "shem-#{tool_id}-#{System.unique_integer([:positive])}"

    {mount_dir, container_path} =
      case Languages.layout(lang) do
        :file -> {Path.dirname(runtime_path), "/workspace/#{Path.basename(runtime_path)}"}
        :dir -> {runtime_path, "/workspace"}
      end

    in_container = [Languages.exe(lang) | Languages.argv(lang, container_path)]

    network_args = if granted["network"], do: [], else: ["--network=none"]
    img = granted["image"] || image(lang)

    extra_mounts =
      Enum.flat_map(granted["mounts"] || [], fn m ->
        ["-v", "#{Path.expand(m["host"])}:#{m["container"]}:#{Map.get(m, "mode", "ro")}"]
      end)

    [
      "run", "-i", "--rm",
      "--name", name,
      "--label", "shem.managed=1",
      "--label", "shem.tool=#{tool_id}"
    ] ++ network_args ++ [
      "-v", "#{mount_dir}:/workspace:ro",
      "-w", "/workspace"
    ] ++ extra_mounts ++ env_args(lang) ++ [img | in_container]
  end

  defp env_args("go"), do: ["-e", "GOPROXY=off"]
  defp env_args(_), do: []

  @spec cleanup_tool(String.t() | nil, String.t()) :: :ok
  def cleanup_tool(nil, _tool_id), do: :ok

  def cleanup_tool(runtime_bin, tool_id) do
    rm_by_filter(runtime_bin, "label=shem.tool=#{tool_id}")
    :ok
  rescue
    e -> Logger.debug("Sandbox.cleanup_tool failed: #{Exception.message(e)}"); :ok
  end

  @spec sweep_orphans(String.t() | nil) :: :ok
  def sweep_orphans(runtime_bin \\ Application.get_env(:shem, :container_runtime_bin))
  def sweep_orphans(nil), do: :ok

  def sweep_orphans(runtime_bin) do
    # async + best-effort: a hard crash can leave --rm containers behind; never block boot.
    Task.start(fn -> rm_by_filter(runtime_bin, "label=shem.managed=1") end)
    :ok
  end

  defp rm_by_filter(runtime_bin, filter) do
    case System.cmd(runtime_bin, ["ps", "-aq", "--filter", filter], stderr_to_stdout: true) do
      {out, 0} ->
        case String.split(out, "\n", trim: true) do
          [] -> :ok
          ids -> System.cmd(runtime_bin, ["rm", "-f" | ids], stderr_to_stdout: true); :ok
        end

      _ ->
        :ok
    end
  end
end
