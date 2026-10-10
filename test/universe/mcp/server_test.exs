defmodule Universe.MCP.ServerTest do
  use ExUnit.Case, async: true

  alias Universe.MCP.Server

  test "exposes exactly tick and inspect, in a fixed order" do
    assert Enum.map(Server.tools(), & &1.name) == ["tick", "inspect"]
    assert Server.server_tools([], nil) == Server.tools()
  end

  test "tool descriptions fit Claude Code's 2,048 character cut" do
    for tool <- Server.tools(), do: assert(String.length(tool.description) < 2048)
  end

  test "the encoded tool list is byte-identical across calls" do
    assert JSON.encode!(Server.tools()) == JSON.encode!(Server.tools())
  end

  test "input validation never rejects, so bad directives reach Universe.API" do
    assert {:ok, %{"directives" => "garbage"}} = Server.accept(%{"directives" => "garbage"})
    assert {:ok, %{}} = Server.accept(nil)
  end

  test "supports the stateless 2026-07-28 protocol" do
    assert "2026-07-28" in Server.supported_protocol_versions()
  end
end
