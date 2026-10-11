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
end
