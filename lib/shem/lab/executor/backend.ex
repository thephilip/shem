defmodule Shem.Lab.Executor.Backend do
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @callback run_shell(cmd :: String.t(), timeout_ms :: non_neg_integer(), opts :: keyword()) ::
              result()
end
