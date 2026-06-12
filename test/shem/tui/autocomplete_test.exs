defmodule Shem.TUI.AutocompleteTest do
  use ExUnit.Case, async: true

  alias Shem.TUI.Autocomplete

  @commands [
    {"/help", "Show this command list (searchable)"},
    {"/preset <name>", "Switch preset"},
    {"/preset list", "List all available presets"},
    {"/agents", "List all running agents"},
    {"/agent <preset> <task>", "Start an agent"}
  ]

  describe "suggest/2" do
    test "matches commands whose first token starts with the typed token" do
      suggestions = Autocomplete.suggest("/pre", @commands)
      assert Enum.map(suggestions, &elem(&1, 0)) == ["/preset <name>", "/preset list"]
    end

    test "bare slash suggests everything" do
      assert length(Autocomplete.suggest("/", @commands)) == 5
    end

    test "matching is on the first token only — arguments don't break it" do
      suggestions = Autocomplete.suggest("/agent gen", @commands)
      assert Enum.map(suggestions, &elem(&1, 0)) == ["/agent <preset> <task>"]
    end

    test "/agents and /agent are distinct prefixes" do
      suggestions = Autocomplete.suggest("/agents", @commands)
      assert Enum.map(suggestions, &elem(&1, 0)) == ["/agents"]
    end

    test "non-slash buffers suggest nothing" do
      assert Autocomplete.suggest("hello", @commands) == []
      assert Autocomplete.suggest("", @commands) == []
    end

    test "no match suggests nothing" do
      assert Autocomplete.suggest("/zzz", @commands) == []
    end
  end

  describe "complete/1" do
    test "completes to the command's first token plus a space" do
      assert Autocomplete.complete({"/preset <name>", "Switch preset"}) == "/preset "
      assert Autocomplete.complete({"/help", "..."}) == "/help "
    end
  end
end
