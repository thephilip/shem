defmodule Shem.Shadow.SupervisorTest do
  use ExUnit.Case, async: true

  test "Shadow.Supervisor is not started when shadow_agent_enabled is false" do
    # config/test.exs sets shadow_agent_enabled: false
    assert Process.whereis(Shem.Shadow.Supervisor) == nil
  end
end
