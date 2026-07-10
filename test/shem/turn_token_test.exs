defmodule Shem.TurnTokenTest do
  use ExUnit.Case, async: true
  alias Shem.TurnToken

  test "round-trips session id and turn tuple" do
    token = TurnToken.encode("sess-abc", {3, 12345})
    assert {:ok, "sess-abc", {3, 12345}} = TurnToken.decode(token)
  end

  test "rejects a tampered payload" do
    token = TurnToken.encode("sess-abc", {3, 12345})
    [p64, s64] = String.split(token, ".")
    forged = Base.url_encode64("sess-EVIL|3|12345|9999999999", padding: false)
    assert {:error, :invalid} = TurnToken.decode(forged <> "." <> s64)
    assert {:error, :invalid} = TurnToken.decode(p64 <> "." <> "AAAA")
  end

  test "rejects an expired token" do
    token = TurnToken.encode("sess-abc", {3, 12345}, ttl: -1)
    assert {:error, :expired} = TurnToken.decode(token)
  end

  test "rejects garbage and the legacy turn:nonce format" do
    assert {:error, :invalid} = TurnToken.decode("3:12345")
    assert {:error, :invalid} = TurnToken.decode("garbage")
    assert {:error, :invalid} = TurnToken.decode("")
    assert {:error, :invalid} = TurnToken.decode(nil)
    assert {:error, :invalid} = TurnToken.decode(%{})
  end

  test "two tokens for the same turn differ only in expiry, both verify" do
    t1 = TurnToken.encode("s", {1, 2})
    t2 = TurnToken.encode("s", {1, 2}, ttl: 60)
    assert {:ok, "s", {1, 2}} = TurnToken.decode(t1)
    assert {:ok, "s", {1, 2}} = TurnToken.decode(t2)
  end
end
