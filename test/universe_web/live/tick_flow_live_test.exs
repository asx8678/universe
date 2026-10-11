defmodule UniverseWeb.TickFlowLiveTest do
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

  defp tick_of(result), do: result.structured["tick"]

  test "a tick's flow shows its lanes and the messages between them", %{conn: conn} do
    svc = uniq("adder")
    job = uniq("job")

    service =
      "def add(a, b):\n    return a + b\nU.serve(#{inspect(svc)}, {'add': add}, 'adds')"

    code =
      "h = U.put('nums', [1, 2])\nU.get(h)\nprint(U.call(#{inspect(svc)}, 'add', {'a': 1, 'b': 2}))"

    result =
      tick([
        %{"op" => "serve", "label" => svc, "lang" => "python", "code" => service},
        %{"op" => "run", "label" => job, "lang" => "python", "code" => code, "after" => [svc]}
      ])

    n = tick_of(result)
    {:ok, view, _html} = live(conn, ~p"/timeline/#{n}")

    assert has_element?(view, "#sequence")
    assert has_element?(view, "#lane-model")
    assert has_element?(view, "#lane-universe")
    assert has_element?(view, "#lane-w\\:#{id_of(result, svc)}", svc)
    assert has_element?(view, "#lane-w\\:#{id_of(result, job)}", job)
    assert has_element?(view, "#lane-handles")

    html = render(view)
    assert html =~ "tick t#{n}: 1 serve, 1 run"
    assert html =~ "serving #{svc}"
    assert html =~ "store h:#{id_of(result, job)}/nums"
    assert html =~ "read h:#{id_of(result, job)}/nums"
    assert html =~ "call add"
    assert html =~ "digest"

    tick([%{"op" => "kill", "target" => svc}], %{"ids" => [svc], "timeout_s" => 10})
  end

  test "the timeline links each tick to its flow; unknown ticks say so", %{conn: conn} do
    result = tick([%{"op" => "run", "label" => uniq("x"), "lang" => "bash", "code" => "true"}])
    n = tick_of(result)

    {:ok, timeline, _} = live(conn, ~p"/timeline")
    assert has_element?(timeline, "#flow-link-#{n}")

    {:ok, view, _} = live(conn, ~p"/timeline/999999")
    assert render(view) =~ "No tick t999999"
  end
end
