defmodule Shem.MCP.Client.ProtocolTest do
  use ExUnit.Case, async: true

  alias Shem.MCP.Client.Protocol

  describe "encode_request/3" do
    test "produces a valid JSON-RPC 2.0 request line" do
      line = Protocol.encode_request(1, "tools/call", %{"name" => "read_file"})
      assert String.ends_with?(line, "\n")
      decoded = Jason.decode!(String.trim_trailing(line))
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["method"] == "tools/call"
      assert decoded["params"] == %{"name" => "read_file"}
    end

    test "encodes id 0 for handshake initialize" do
      line = Protocol.encode_request(0, "initialize", %{})
      decoded = Jason.decode!(String.trim_trailing(line))
      assert decoded["id"] == 0
    end
  end

  describe "encode_notification/2" do
    test "produces a JSON-RPC 2.0 notification (no id field)" do
      line = Protocol.encode_notification("notifications/initialized", %{})
      assert String.ends_with?(line, "\n")
      decoded = Jason.decode!(String.trim_trailing(line))
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "notifications/initialized"
      refute Map.has_key?(decoded, "id")
    end
  end

  describe "decode_message/1" do
    test "decodes a valid JSON-RPC 2.0 response" do
      line = ~s({"jsonrpc":"2.0","id":1,"result":{"ok":true}})
      assert {:ok, %{"id" => 1, "result" => %{"ok" => true}}} = Protocol.decode_message(line)
    end

    test "returns error for invalid JSON" do
      assert {:error, :invalid_json} = Protocol.decode_message("not json")
    end

    test "returns error for JSON missing jsonrpc field" do
      assert {:error, :unknown_shape} = Protocol.decode_message(~s({"id":1}))
    end

    test "returns error for jsonrpc version other than 2.0" do
      assert {:error, :unknown_shape} =
               Protocol.decode_message(~s({"jsonrpc":"1.0","id":1,"result":{}}))
    end
  end
end
