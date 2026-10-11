defmodule UniverseWeb.SystemLiveTest do
  use UniverseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defp uniq(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp tick(directives, wait \\ %{"timeout_s" => 30}),
    do: Universe.API.tick(%{"directives" => directives, "wait" => wait})

  defp id_of(result, label) do
    Enum.find_value(result.structured["ids"], fn {"#" <> id, v} ->
      v["label"] == label && String.to_integer(id)
    end)
  end

  test "shows the supervision tree with kinds, strategies and roles", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/system")

    assert has_element?(view, "#node-Universe-Supervisor", "supervisor")
    assert has_element?(view, "#node-Universe-Supervisor", "one_for_one")
    assert has_element?(view, "#node-Universe-Runtime", "rest_for_one")
    assert has_element?(view, "#node-Universe-Tick", "GenServer")
    assert has_element?(view, "#node-Universe-Tick", "The kernel")
    assert has_element?(view, "#node-Universe-WorkerSup", "dynamic supervisor")
    assert has_element?(view, "#node-Universe-TaskSup", "task supervisor")
    assert has_element?(view, "#system-totals")
  end

  test "a running worker appears under WorkerSup with its OS processes", %{conn: conn} do
    label = uniq("tree")

    result =
      tick([%{"op" => "run", "label" => label, "lang" => "bash", "code" => "sleep 20"}], %{
        "timeout_s" => 1
      })

    id = id_of(result, label)

    {:ok, view, _html} = live(conn, ~p"/system")
    html = render(view)

    assert html =~ "##{id} #{label}"
    assert html =~ "universe_run"
    assert html =~ "sleep 20"

    tick([%{"op" => "kill", "target" => label}], %{"ids" => [label], "timeout_s" => 10})
  end

  test "library supervisors expand on demand", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/system")
    assert has_element?(view, "#toggle-UniverseWeb-Endpoint", "children")

    view |> element("#toggle-UniverseWeb-Endpoint") |> render_click()
    assert has_element?(view, "#toggle-UniverseWeb-Endpoint", "hide children")
  end
end
