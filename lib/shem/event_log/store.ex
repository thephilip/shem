defmodule Shem.EventLog.Store do
  alias Shem.EventLog.Event

  @callback open(session_id :: String.t(), path :: Path.t()) ::
              {:ok, handle :: term()} | {:error, term()}

  @callback append(handle :: term(), event :: Event.t()) ::
              :ok | {:error, term()}

  @callback read_all(handle :: term()) ::
              {:ok, [Event.t()]} | {:error, term()}

  @callback get(handle :: term(), event_id :: String.t()) ::
              {:ok, Event.t()} | {:error, :not_found}

  @callback close(handle :: term()) :: :ok
end
