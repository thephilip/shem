defmodule Shem.REST.PresetsTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Shem.REST.Router

  @opts Router.init([])

  test "GET /presets returns JSON list with name and description" do
    conn = conn(:get, "/presets") |> Router.call(@opts)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    body = Jason.decode!(conn.resp_body)
    assert is_list(body)
    assert length(body) >= 3
    first = hd(body)
    assert Map.has_key?(first, "name")
    assert Map.has_key?(first, "description")
  end

  test "GET /unknown returns JSON 404" do
    conn = conn(:get, "/unknown") |> Router.call(@opts)
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "not found"}
  end

  describe "POST /presets" do
    setup do
      on_exit(fn ->
        Shem.Agent.PresetStore.delete("new-preset")
        Shem.Agent.PresetStore.delete("dupe-preset")
      end)
      :ok
    end

    test "returns 201 with preset object on valid input" do
      conn =
        conn(:post, "/presets", Jason.encode!(%{name: "new-preset", system_prompt: "Be helpful."}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["name"] == "new-preset"
      assert body["description"] == "Be helpful."
      assert body["deletable"] == true
    end

    test "returns 422 when name is missing" do
      conn =
        conn(:post, "/presets", Jason.encode!(%{system_prompt: "Be helpful."}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["error"] =~ "required"
    end

    test "returns 422 when system_prompt is missing" do
      conn =
        conn(:post, "/presets", Jason.encode!(%{name: "new-preset"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["error"] =~ "required"
    end

    test "returns 422 when name is blank" do
      conn =
        conn(:post, "/presets", Jason.encode!(%{name: "  ", system_prompt: "Be helpful."}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["error"] =~ "required"
    end

    test "returns 409 when name already exists as a built-in" do
      conn =
        conn(:post, "/presets", Jason.encode!(%{name: "general", system_prompt: "Override."}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["error"] =~ "already exists"
    end

    test "returns 409 when name already exists as a user preset" do
      Shem.Agent.PresetStore.put("dupe-preset", %{name: "dupe-preset", system_prompt: "First."})

      conn =
        conn(:post, "/presets", Jason.encode!(%{name: "dupe-preset", system_prompt: "Second."}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["error"] =~ "already exists"
    end
  end

  describe "DELETE /presets/:name" do
    setup do
      Shem.Agent.PresetStore.put("deletable-preset", %{
        name: "deletable-preset",
        system_prompt: "Delete me."
      })
      on_exit(fn -> Shem.Agent.PresetStore.delete("deletable-preset") end)
      :ok
    end

    test "returns 204 and removes the preset" do
      conn =
        conn(:delete, "/presets/deletable-preset")
        |> Router.call(@opts)

      assert conn.status == 204
      assert conn.resp_body == ""

      conn2 = conn(:get, "/presets") |> Router.call(@opts)
      body = Jason.decode!(conn2.resp_body)
      refute Enum.any?(body, &(&1["name"] == "deletable-preset"))
    end

    test "returns 404 for unknown preset name" do
      conn =
        conn(:delete, "/presets/no-such-preset-#{System.unique_integer([:positive])}")
        |> Router.call(@opts)

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] =~ "not found"
    end

    test "returns 403 for built-in preset" do
      conn =
        conn(:delete, "/presets/general")
        |> Router.call(@opts)

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] =~ "cannot delete"
    end

    test "returns 403 for explorer built-in preset" do
      conn =
        conn(:delete, "/presets/explorer")
        |> Router.call(@opts)

      assert conn.status == 403
    end
  end

  describe "GET /presets — deletable field" do
    test "built-in presets have deletable: false" do
      conn = conn(:get, "/presets") |> Router.call(@opts)
      body = Jason.decode!(conn.resp_body)
      general = Enum.find(body, &(&1["name"] == "general"))
      assert general != nil
      assert general["deletable"] == false
    end

    test "user-created presets have deletable: true" do
      Shem.Agent.PresetStore.put("test-preset-get", %{
        name: "test-preset-get",
        system_prompt: "Test prompt"
      })
      on_exit(fn -> Shem.Agent.PresetStore.delete("test-preset-get") end)

      conn = conn(:get, "/presets") |> Router.call(@opts)
      body = Jason.decode!(conn.resp_body)
      preset = Enum.find(body, &(&1["name"] == "test-preset-get"))
      assert preset != nil
      assert preset["deletable"] == true
    end
  end
end
