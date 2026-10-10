defmodule UniverseWeb.HookControllerTest do
  use UniverseWeb.ConnCase, async: false

  setup do
    File.mkdir_p!(Universe.Paths.universe_dir())
    File.write!(Universe.Paths.token_file(), "hook-test-token")

    conn =
      %{build_conn() | host: "127.0.0.1"}
      |> put_req_header("authorization", "Bearer hook-test-token")

    {:ok, conn: conn}
  end

  test "GET /hooks/manifest returns the plain-text manifest", %{conn: conn} do
    body = conn |> get("/hooks/manifest") |> text_response(200)
    assert body =~ "manifest · "
    assert body =~ "services:"
  end

  test "POST /hooks/redirect records the blocked command", %{conn: conn} do
    payload = %{"tool_name" => "Bash", "tool_input" => %{"command" => "mix test"}}

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/hooks/redirect", Jason.encode!(payload))
    |> text_response(200)

    assert Enum.any?(
             Universe.EventLog.since(0),
             &(&1["type"] == "redirect" and &1["data"]["command"] == "mix test")
           )
  end

  test "hooks need the token" do
    conn = %{build_conn() | host: "127.0.0.1"} |> get("/hooks/manifest")
    assert conn.status == 401
  end
end
