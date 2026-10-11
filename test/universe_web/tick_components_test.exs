defmodule UniverseWeb.TickComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias UniverseWeb.TickComponents

  # tick_in keeps what the model sent, before validation, and older logs hold
  # waits that were never checked: a card must render whatever is there.
  test "a tick card shows odd logged values as text instead of crashing" do
    tick_in = %{
      "type" => "tick_in",
      "tick" => 115,
      "ts" => "2026-10-11T10:00:00Z",
      "data" => %{
        "wait" => %{"ids" => [%{"a" => 1}, "#5", 7], "timeout_s" => 2},
        "directives" => [
          %{"op" => "call", "label" => "c", "service" => "pg", "fn" => %{"x" => 1}},
          %{
            "op" => "run",
            "label" => "r",
            "after" => [%{"b" => 2}, "#3"],
            "leases" => [1, "lib"]
          },
          "not a directive"
        ]
      }
    }

    html =
      render_component(&TickComponents.tick_card/1,
        id: "t115",
        tick: TickComponents.build_tick(115, [tick_in])
      )

    assert html =~ "Wakes when all of {&quot;a&quot;:1}, #5, 7 settle"
    assert html =~ "pg.{&quot;x&quot;:1}"
    assert html =~ "after {&quot;b&quot;:2}, #3"
    assert html =~ "leases 1, lib"
  end
end
