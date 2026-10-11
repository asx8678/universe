defmodule UniverseWeb.Plugs.LoopbackOnlyTest do
  use UniverseWeb.ConnCase, async: true

  test "observer pages answer localhost, not other hosts (DNS rebinding)", %{conn: conn} do
    assert conn |> get("/workers") |> html_response(200)

    for host <- ["evil.example.com", "127.0.0.1.nip.io"] do
      denied = %{conn | host: host} |> get("/workers")
      assert denied.status == 403
      assert denied.resp_body == "bad host"
    end
  end

  test "a foreign Origin and a non-loopback peer are refused", %{conn: conn} do
    assert get(put_req_header(conn, "origin", "http://evil.example.com"), "/").status == 403
    assert get(%{conn | remote_ip: {10, 0, 0, 5}}, "/").status == 403
    assert get(put_req_header(conn, "origin", "http://localhost:4000"), "/").status == 200
  end

  test "LiveDashboard is served behind the same guard", %{conn: conn} do
    # It redirects to its home page; following it renders the dashboard.
    resp = get(conn, "/dashboard")
    assert resp.status in [200, 302]
    assert get(%{conn | host: "evil.example.com"}, "/dashboard").status == 403
  end
end
