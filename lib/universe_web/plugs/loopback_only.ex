defmodule UniverseWeb.Plugs.LoopbackOnly do
  @moduledoc """
  Loopback peers only, with a local `Host` and no foreign `Origin`.

  The daemon listens on 127.0.0.1, but a web page elsewhere can still reach
  it through DNS rebinding: a name that resolves to 127.0.0.1 sends requests
  with its own `Host`. Checking `Host` and `Origin` closes that. Used for the
  observer pages (including LiveDashboard) and, with a token check on top, by
  `UniverseWeb.Plugs.MCPGuard`.
  """

  @behaviour Plug

  import Plug.Conn

  @loopback_hosts ["127.0.0.1", "localhost", "[::1]", "::1"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case check(conn) do
      :ok -> conn
      {:error, reason} -> deny(conn, 403, reason)
    end
  end

  @doc "`:ok`, or `{:error, reason}` for a request from outside this machine."
  def check(conn) do
    cond do
      not loopback?(conn.remote_ip) -> {:error, "loopback only"}
      not local_host?(conn.host) -> {:error, "bad host"}
      not allowed_origin?(get_req_header(conn, "origin")) -> {:error, "bad origin"}
      true -> :ok
    end
  end

  @doc false
  def deny(conn, status, reason) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, reason)
    |> halt()
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, a, _}), do: div(a, 256) == 127
  defp loopback?(_), do: false

  defp local_host?(host), do: host in @loopback_hosts

  # Absent Origin is fine (CLIs and plain navigation); a present one must be local.
  defp allowed_origin?([]), do: true

  defp allowed_origin?([origin | _]) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] -> local_host?(host)
      _ -> false
    end
  end
end
