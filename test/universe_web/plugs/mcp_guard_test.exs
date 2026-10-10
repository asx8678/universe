defmodule UniverseWeb.Plugs.MCPGuardTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias UniverseWeb.Plugs.MCPGuard

  @token "s3cret-token"

  defp call(conn, token \\ @token), do: MCPGuard.call(conn, MCPGuard.init(token: token))

  defp request(opts \\ []) do
    conn(:post, "/mcp", "{}")
    |> Map.put(:remote_ip, Keyword.get(opts, :ip, {127, 0, 0, 1}))
    |> Map.put(:host, Keyword.get(opts, :host, "127.0.0.1"))
    |> then(fn conn ->
      Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {k, v}, c ->
        put_req_header(c, k, v)
      end)
    end)
  end

  defp authed(opts \\ []) do
    request(
      Keyword.update(
        opts,
        :headers,
        [{"authorization", "Bearer #{@token}"}],
        &[{"authorization", "Bearer #{@token}"} | &1]
      )
    )
  end

  test "passes a loopback request with the right token" do
    refute call(authed()).halted
  end

  test "accepts IPv6 loopback and IPv4-mapped loopback" do
    refute call(authed(ip: {0, 0, 0, 0, 0, 0, 0, 1}, host: "localhost")).halted
    refute call(authed(ip: {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1})).halted
  end

  test "rejects a missing or wrong token with 401" do
    assert %{status: 401, halted: true} = call(request())
    assert %{status: 401} = call(request(headers: [{"authorization", "Bearer nope"}]))
    assert %{status: 401} = call(request(headers: [{"authorization", @token}]))
  end

  test "rejects everything when no token is configured" do
    assert %{status: 401} = call(authed(), nil)
  end

  test "rejects non-loopback peers with 403" do
    assert %{status: 403} = call(authed(ip: {192, 168, 1, 20}))
  end

  test "rejects foreign Host and Origin headers (DNS rebinding)" do
    assert %{status: 403} = call(authed(host: "evil.example"))
    assert %{status: 403} = call(authed(headers: [{"origin", "http://evil.example"}]))
    assert %{status: 403} = call(authed(headers: [{"origin", "null"}]))
    refute call(authed(headers: [{"origin", "http://localhost:4000"}])).halted
  end
end
