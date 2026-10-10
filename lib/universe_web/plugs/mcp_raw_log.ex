defmodule UniverseWeb.Plugs.MCPRawLog do
  @moduledoc """
  Appends every MCP request (method, protocol headers, body) to
  `.universe/log/mcp_raw.jsonl`. Used in M0 to learn exactly what the client
  speaks; enabled with `config :universe, log_raw_mcp: true`.
  """

  @behaviour Plug

  import Plug.Conn

  @headers ~w(mcp-protocol-version mcp-method mcp-name mcp-session-id user-agent accept content-type)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Application.get_env(:universe, :log_raw_mcp, false), do: write(conn)
    conn
  end

  defp write(conn) do
    dir = Universe.Paths.log_dir()
    File.mkdir_p!(dir)

    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      http_method: conn.method,
      headers: Map.new(@headers, &{&1, conn |> get_req_header(&1) |> List.first()}),
      body: body(conn.body_params)
    }

    File.write!(Path.join(dir, "mcp_raw.jsonl"), [Jason.encode!(entry), ?\n], [:append])
  end

  defp body(%Plug.Conn.Unfetched{}), do: nil
  defp body(params), do: params
end
