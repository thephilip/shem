defmodule Shem.ApplicationTest do
  use ExUnit.Case, async: false

  test "MnesiaStore table exists after application start" do
    # The application starts in test setup — just verify the table is present
    tables = :mnesia.system_info(:tables)
    assert :shem_events in tables
  end
end
