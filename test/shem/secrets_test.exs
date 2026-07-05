defmodule Shem.SecretsTest do
  use ExUnit.Case, async: false
  alias Shem.Secrets

  setup do
    on_exit(fn ->
      Application.delete_env(:shem, :secret_provider)
      Application.delete_env(:shem, :secret_resolver_fn)
    end)
  end

  test "args without handles pass through untouched, provider not needed" do
    args = %{"a" => 1, "b" => %{"c" => [1, 2]}}
    assert {:ok, ^args} = Secrets.resolve(args)
  end

  test "handle with no provider configured fails" do
    assert {:error, msg} = Secrets.resolve(%{"token" => %{"$secret" => "api_key"}})
    assert msg =~ "secret_provider"
  end

  test "handles resolve recursively through maps and lists" do
    Application.put_env(:shem, :secret_provider, "secret_store")
    Application.put_env(:shem, :secret_resolver_fn, fn
      "api_key" -> {:ok, "PLAIN"}
      k -> {:error, "unknown key #{k}"}
    end)

    args = %{"token" => %{"$secret" => "api_key"},
             "nested" => [%{"x" => %{"$secret" => "api_key"}}]}
    assert {:ok, resolved} = Secrets.resolve(args)
    assert resolved["token"] == "PLAIN"
    assert [%{"x" => "PLAIN"}] = resolved["nested"]
  end

  test "unknown key fails the whole resolution" do
    Application.put_env(:shem, :secret_provider, "secret_store")
    Application.put_env(:shem, :secret_resolver_fn, fn _ -> {:error, :not_found} end)
    assert {:error, _} = Secrets.resolve(%{"t" => %{"$secret" => "nope"}})
  end

  test "a map with $secret plus other keys is NOT a handle" do
    args = %{"m" => %{"$secret" => "k", "other" => 1}}
    assert {:ok, ^args} = Secrets.resolve(args)
  end
end
