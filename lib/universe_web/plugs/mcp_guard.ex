defmodule UniverseWeb.Plugs.MCPGuard do
  @moduledoc """
  Gatekeeper for `/mcp` and the hook endpoints: the loopback, `Host` and
  `Origin` checks of `UniverseWeb.Plugs.LoopbackOnly`, plus
  `Authorization: Bearer <token>` matching `.universe/token`. Failures are
  plain HTTP errors, never MCP results.
  """

  @behaviour Plug

  import Plug.Conn

  alias UniverseWeb.Plugs.LoopbackOnly

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    token = Keyword.get_lazy(opts, :token, &expected_token/0)

    with :ok <- LoopbackOnly.check(conn),
         true <- authorized?(get_req_header(conn, "authorization"), token) do
      conn
    else
      {:error, reason} -> LoopbackOnly.deny(conn, 403, reason)
      false -> LoopbackOnly.deny(conn, 401, "unauthorized")
    end
  end

  defp expected_token, do: Universe.Paths.read_token()

  defp authorized?(_header, nil), do: false

  defp authorized?(["Bearer " <> given | _], token),
    do: Plug.Crypto.secure_compare(String.trim(given), token)

  defp authorized?(_header, _token), do: false
end
