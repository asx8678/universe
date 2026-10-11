defmodule UniverseWeb.ObserverPagesTest do
  use UniverseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup_all do
    label = "obs-#{System.unique_integer([:positive])}"

    result =
      Universe.API.tick(%{
        "directives" => [
          %{
            "op" => "run",
            "label" => label,
            "lang" => "python",
            "code" => "U.put('obs', [{'k': 1}, {'k': 2}])\nprint('observed')"
          }
        ]
      })

    [{"#" <> id, _}] = Map.to_list(result.structured["ids"])
    %{id: id, label: label}
  end

  test "workers page lists workers and links to them", %{conn: conn, id: id, label: label} do
    {:ok, view, html} = live(conn, ~p"/workers")
    assert html =~ label
    assert has_element?(view, "#worker-#{id} a", "##{id}")
  end

  test "worker page shows code, output and handles", %{conn: conn, id: id} do
    {:ok, _view, html} = live(conn, ~p"/workers/#{id}")
    assert html =~ "U.put("
    assert html =~ "observed"
    assert html =~ "h:#{id}/obs"
  end

  test "handles page previews a handle", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/handles")
    html = view |> element("#h-h-#{id}-obs") |> render_click()
    assert html =~ "2 rows × 1 cols"
  end

  test "replay renders the saved event log offline", %{conn: conn, label: label} do
    :ok = Universe.EventLog.sync()
    {:ok, _view, html} = live(conn, ~p"/replay/events.jsonl")
    assert html =~ label
    {:ok, _view, html} = live(conn, ~p"/replay/nope.jsonl")
    assert html =~ "no log named"

    # Picking a file from the list patches to it.
    {:ok, view, _html} = live(conn, ~p"/replay")
    view |> element("#replay-files a", "events.jsonl") |> render_click()
    assert_patch(view, ~p"/replay/events.jsonl")
    assert render(view) =~ label
  end

  test "stop all kills live workers and reports it", %{conn: conn} do
    label = "stopme-#{System.unique_integer([:positive])}"

    Universe.API.tick(%{
      "directives" => [%{"op" => "run", "label" => label, "lang" => "bash", "code" => "sleep 30"}],
      "wait" => %{"timeout_s" => 0}
    })

    {:ok, view, _html} = live(conn, ~p"/")
    assert render_click(view, "stop_all") =~ "Stopped"

    result =
      Universe.API.tick(%{"directives" => [], "wait" => %{"ids" => [label], "timeout_s" => 10}})

    assert result.text =~ ~r/killed\s+#{label}/
  end
end
