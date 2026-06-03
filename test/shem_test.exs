defmodule ShemTest do
  use ExUnit.Case
  doctest Shem

  test "greets the world" do
    assert Shem.hello() == :world
  end
end
