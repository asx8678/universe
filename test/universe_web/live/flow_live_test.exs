defmodule UniverseWeb.FlowLiveTest do
  use UniverseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defp uniq(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp tick(directives, wait \\ %{"timeout_s" => 30}),
    do: Universe.API.tick(%{"directives" => directives, "wait" => wait})

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        flunk("condition never became true")

      true ->
        receive do
        after
          50 -> eventually(fun, tries - 1)
        end
    end
  end

  test "the graph shows the model, Universe and workers; fresh edges animate", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/flow")
    assert has_element?(view, "#node-model")
    assert has_element?(view, "#node-universe")

    label = uniq("flowjob")

    result =
      tick([%{"op" => "run", "label" => label, "lang" => "python", "code" => "U.put('x', [1])"}])

    [{"#" <> id, _}] = Map.to_list(result.structured["ids"])

    eventually(fn -> has_element?(view, "#node-w-#{id}", label) end)

    assert has_element?(view, "#edge-model--universe")
    assert has_element?(view, "#edge-w-#{id}--handles")
    eventually(fn -> has_element?(view, "#edge-model--universe.flow-edge-active") end)
    assert has_element?(view, "#flow-recent", "store h:#{id}/x")
  end

  test "clicking a node opens its details; clicking again or close shuts them", %{conn: conn} do
    label = uniq("detail")

    result =
      tick([%{"op" => "run", "label" => label, "lang" => "python", "code" => "print('hi')"}])

    [{"#" <> id, _}] = Map.to_list(result.structured["ids"])
    {:ok, view, _html} = live(conn, ~p"/flow")
    refute has_element?(view, "#flow-details-close")

    view |> element("#node-w-#{id}") |> render_click()
    assert has_element?(view, "#flow-details", "##{id} #{label}")
    assert has_element?(view, "#flow-details-doing", "Done")
    assert has_element?(view, "#flow-details-links", "Universe")
    assert has_element?(view, "#node-w-#{id}.flow-node-selected")
    assert has_element?(view, ~s(#flow-details-open[href="/workers/#{id}"]))

    view |> element("#node-w-#{id}") |> render_click()
    refute has_element?(view, "#flow-details-close")

    view |> element("#node-universe") |> render_click()
    assert has_element?(view, "#flow-details", "kernel")
    view |> element("#flow-details-close") |> render_click()
    refute has_element?(view, ".flow-node-selected")
  end

  test "a long-lived worker's details still show how it started", %{conn: conn} do
    label = uniq("chatty")

    result =
      tick([%{"op" => "run", "label" => label, "lang" => "python", "code" => "print('hi')"}])

    [{"#" <> id, _}] = Map.to_list(result.structured["ids"])
    # More events than the details read from the end.
    for i <- 1..450,
        do:
          Universe.EventLog.append("test_noise",
            id: String.to_integer(id),
            data: %{"text" => "p#{i}"}
          )

    {:ok, view, _html} = live(conn, ~p"/flow?node=w:#{id}")
    assert has_element?(view, "#flow-details", "python")
    # Move the digest cursor past the extra events, so the next tick is clean.
    tick([], %{"timeout_s" => 0})
  end

  test "the handles node's count follows new handles", %{conn: conn} do
    stored = fn n -> ~s(#flow-details dd[title="#{n}"]) end
    {:ok, view, _html} = live(conn, ~p"/flow")

    tick([
      %{"op" => "run", "label" => uniq("putter"), "lang" => "python", "code" => "U.put('a', [1])"}
    ])

    eventually(fn -> has_element?(view, "#node-handles") end)
    view |> element("#node-handles") |> render_click()
    before = length(Universe.Handles.list())
    eventually(fn -> has_element?(view, stored.(before)) end)

    tick([
      %{"op" => "run", "label" => uniq("putter"), "lang" => "python", "code" => "U.put('b', [2])"}
    ])

    eventually(fn -> has_element?(view, stored.(before + 1)) end)
  end
end
