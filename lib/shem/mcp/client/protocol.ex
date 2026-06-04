defmodule Shem.MCP.Client.Protocol do
  @spec encode_request(id :: non_neg_integer(), method :: String.t(), params :: map()) :: String.t()
  def encode_request(id, method, params) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}) <>
      "\n"
  end

  @spec encode_notification(method :: String.t(), params :: map()) :: String.t()
  def encode_notification(method, params) do
    Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params}) <> "\n"
  end

  @spec decode_message(line :: String.t()) ::
          {:ok, map()} | {:error, :invalid_json | :unknown_shape}
  def decode_message(line) do
    case Jason.decode(line) do
      {:ok, %{"jsonrpc" => "2.0"} = msg} -> {:ok, msg}
      {:ok, _} -> {:error, :unknown_shape}
      {:error, _} -> {:error, :invalid_json}
    end
  end
end
