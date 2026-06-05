defmodule Shem.Adversarial do
  alias Shem.Adversarial.{Supervisor, HardeningJob}
  alias Shem.ProcessRegistry

  @spec start_hardening(String.t()) ::
          {:ok, String.t()} | {:ok, :disabled} | {:error, term()}
  def start_hardening(tool_id) do
    case Process.whereis(Supervisor) do
      nil ->
        {:ok, :disabled}

      _pid ->
        job_name = "hardening_" <> Base.encode16(:crypto.strong_rand_bytes(4))
        via = ProcessRegistry.via_tuple(job_name)

        case DynamicSupervisor.start_child(Supervisor, {HardeningJob, {tool_id, [name: via]}}) do
          {:ok, _pid} -> {:ok, job_name}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(job_name) do
    case GenServer.whereis(ProcessRegistry.via_tuple(job_name)) do
      nil -> {:error, :not_found}
      pid -> {:ok, GenServer.call(pid, :status)}
    end
  end
end
