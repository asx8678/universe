defmodule UniverseWeb.Plugs.MCPRawLog do
  @moduledoc """
  Appends every MCP request (method, protocol headers, body) to
  `.universe/log/mcp_raw.jsonl`. Used in M0 to learn exactly what the client
  speaks; enabled with `config :universe, log_raw_mcp: true`.

  Bodies go through the same secret redaction as the event log, are cut at
  @max_body bytes, and the file stops growing at @max_file bytes.
  """

  @behaviour Plug

  import Plug.Conn

  @max_body 64 * 1024
  @max_file 50 * 1024 * 1024
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
    path = Path.join(dir, "mcp_raw.jsonl")

    full? = match?({:ok, %File.Stat{size: size}} when size >= @max_file, File.stat(path))

    unless full? do
      body =
        conn.body_params
        |> body()
        |> Universe.Redact.scrub(Universe.Secrets.all())
        |> Jason.encode!()

      body =
        if byte_size(body) > @max_body,
          do: %{
            "truncated" => true,
            "head" => Universe.Worker.utf8(binary_slice(body, 0, @max_body))
          },
          else: Jason.decode!(body)

      entry = %{
        ts: DateTime.utc_now() |> DateTime.to_iso8601(),
        http_method: conn.method,
        headers: Map.new(@headers, &{&1, conn |> get_req_header(&1) |> List.first()}),
        body: body
      }

      File.write!(path, [Jason.encode!(entry), ?\n], [:append])
    end
  end

  defp body(%Plug.Conn.Unfetched{}), do: nil
  defp body(params), do: params
end
