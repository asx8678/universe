defmodule UniverseWeb.Plugs.MCPGuard do
  @moduledoc """
  Gatekeeper for `/mcp`: loopback peers only, no foreign `Origin` or `Host`
  (DNS-rebinding protection), and `Authorization: Bearer <token>` matching
  `.universe/token`. Failures are plain HTTP errors, never MCP results.
  """

  @behaviour Plug

  import Plug.Conn

  @loopback_hosts ["127.0.0.1", "localhost", "[::1]"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    token = Keyword.get_lazy(opts, :token, &expected_token/0)

    cond do
      not loopback?(conn.remote_ip) ->
        deny(conn, 403, "loopback only")

      not local_host?(conn.host) ->
        deny(conn, 403, "bad host")

      not allowed_origin?(get_req_header(conn, "origin")) ->
        deny(conn, 403, "bad origin")

      not authorized?(get_req_header(conn, "authorization"), token) ->
        deny(conn, 401, "unauthorized")

      true ->
        conn
    end
  end

  defp expected_token, do: Universe.Paths.read_token()

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, a, _}), do: div(a, 256) == 127
  defp loopback?(_), do: false

  defp local_host?(host), do: host in @loopback_hosts or host == "::1"

  # Absent Origin is fine (CLIs don't send one); a present one must be local.
  defp allowed_origin?([]), do: true

  defp allowed_origin?([origin | _]) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] -> local_host?(host)
      _ -> false
    end
  end

  defp authorized?(_header, nil), do: false

  defp authorized?(["Bearer " <> given | _], token),
    do: Plug.Crypto.secure_compare(String.trim(given), token)

  defp authorized?(_header, _token), do: false

  defp deny(conn, status, reason) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, reason)
    |> halt()
  end
end
