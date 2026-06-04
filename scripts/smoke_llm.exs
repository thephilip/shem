# Run with: mix run scripts/smoke_llm.exs
# Requires an LLM server configured in config/dev.exs (Ollama or llama.cpp).
# Verifies: LLM call succeeds, tokens tracked, event log records the call.

Application.put_env(:shem, :start_tui, false)
Application.put_env(:shem, :start_mcp, false)
Application.ensure_all_started(:shem)

model = Application.get_env(:shem, :llm_models, %{}) |> Map.get(:default, "llama3:latest")
IO.puts("Using model config: #{inspect(model)}")
IO.puts("Sending test prompt to LLM server...\n")

{:ok, sid} = Shem.EventLog.start_session()

request = %Shem.LLM.Request{
  prompt: "In one sentence, what is the Elixir programming language?",
  model: :default,
  session_id: sid
}

case Shem.LLM.complete(request) do
  {:ok, response} ->
    IO.puts("Response: #{response.content}")
    IO.puts("Tokens used: #{response.tokens_used}")
    IO.puts("Latency: #{response.latency_ms}ms")

    {:ok, events} = Shem.EventLog.events(sid)
    types = Enum.map(events, & &1.type)
    IO.puts("\nEvent log entries: #{inspect(types)}")

    if :llm_call_started in types and :llm_call_completed in types do
      IO.puts("\n✓ Smoke test passed.")
    else
      IO.puts("\n✗ Event log entries missing — expected :llm_call_started and :llm_call_completed")
      System.halt(1)
    end

  {:error, reason} ->
    IO.puts("✗ LLM call failed: #{inspect(reason)}")
    IO.puts("Is your LLM server running and configured in config/dev.exs?")
    System.halt(1)
end
