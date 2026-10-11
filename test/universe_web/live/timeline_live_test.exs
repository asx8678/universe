defmodule UniverseWeb.TimelineLiveTest do
  use UniverseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "shows ticks with directives and digests, and updates live", %{conn: conn} do
    label = "tl-#{System.unique_integer([:positive])}"
    run = %{"op" => "run", "label" => label, "lang" => "bash", "code" => "echo from-timeline"}
    first = Universe.API.tick(%{"directives" => [run]})

    {:ok, view, html} = live(conn, ~p"/timeline")
    assert html =~ "Tick timeline"
    assert html =~ "t#{first.structured["tick"]}"
    assert html =~ label
    assert html =~ "from-timeline"

    second = Universe.API.tick(%{"directives" => [], "wait" => %{"timeout_s" => 0}})
    assert render(view) =~ "t#{second.structured["tick"]}"
  end
end
