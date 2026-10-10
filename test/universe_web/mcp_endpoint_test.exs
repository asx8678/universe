defmodule UniverseWeb.MCPEndpointTest do
  # Shares the test project's .universe/token, so not async.
  use UniverseWeb.ConnCase, async: false

  @version "2026-07-28"

  setup do
    File.mkdir_p!(Universe.Paths.universe_dir())
    File.write!(Universe.Paths.token_file(), "endpoint-test-token")
    # Phoenix.ConnTest defaults to www.example.com, which the guard rejects.
    {:ok, conn: %{build_conn() | host: "127.0.0.1"}}
  end

  # The request shape Claude Code 2.1.296 sends in the stateless era.
  defp rpc(conn, method, params) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{},
      "io.modelcontextprotocol/clientInfo" => %{"name" => "test", "version" => "0"}
    }

    conn
    |> put_req_header("authorization", "Bearer endpoint-test-token")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @version)
    |> put_req_header("mcp-method", method)
    |> then(&if(name = params["name"], do: put_req_header(&1, "mcp-name", name), else: &1))
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: method,
        params: Map.put(params, "_meta", meta)
      })
    )
  end

  defp result(conn) do
    body = response(conn, 200)

    json =
      if String.contains?(body, "data: ") do
        body
        |> String.split("\n")
        |> Enum.find_value(
          &(String.starts_with?(&1, "data: ") && String.trim_leading(&1, "data: "))
        )
      else
        body
      end

    Jason.decode!(json)["result"]
  end

  test "tools/list returns tick then inspect", %{conn: conn} do
    assert %{"tools" => tools} = conn |> rpc("tools/list", %{}) |> result()
    assert Enum.map(tools, & &1["name"]) == ["tick", "inspect"]
  end

  test "tools/call tick returns the digest as text only", %{conn: conn} do
    res =
      conn
      |> rpc("tools/call", %{"name" => "tick", "arguments" => %{"directives" => []}})
      |> result()

    assert [%{"type" => "text", "text" => text}] = res["content"]
    assert text =~ ~r/^t\d+ · 0 changed · cursor \d+/
    refute Map.has_key?(res, "structuredContent")
  end

  test "requests without the token never reach the server", %{conn: conn} do
    conn = conn |> put_req_header("content-type", "application/json") |> post("/mcp", "{}")
    assert conn.status == 401
  end
end
