defmodule UniverseWeb.TopologyViewTest do
  # The Flow graph's markup: one line per pair, lit while a message crosses.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias UniverseWeb.{FlowComponents, Topology}

  defp ev(seq, type, id, data),
    do: %{
      "seq" => seq,
      "type" => type,
      "id" => id,
      "tick" => 1,
      "ts" => "2026-10-11T10:00:00Z",
      "data" => data
    }

  defp graph do
    events = [
      ev(1, "tick_in", nil, %{"directives" => [%{"op" => "run"}]}),
      ev(2, "spawn", 5, %{"label" => "pg", "kind" => "serve", "lang" => "python"}),
      ev(3, "serve", 5, %{"name" => "pg"}),
      ev(4, "spawn", 6, %{"label" => "job", "kind" => "run", "lang" => "python"}),
      ev(5, "call", 6, %{"service" => "pg", "fn" => "q", "via" => "sdk", "ok" => true}),
      ev(6, "tick_out", nil, %{"wake" => "settled", "tokens_out_est" => 9})
    ]

    worker = fn
      5 -> %{label: "pg", kind: "serve", lang: "python"}
      6 -> %{label: "job", kind: "run", lang: "python"}
    end

    Topology.build(events, %{}, worker: worker, owner: fn "pg", _ -> 5 end)
  end

  defp render(active),
    do: render_component(&FlowComponents.topology/1, graph: graph(), active: MapSet.new(active))

  test "both directions of a pair share one line, keyed left to right" do
    html = render([])
    assert html =~ ~s(id="edge-model--universe")
    refute html =~ ~s(id="edge-universe--model")
    assert html =~ ~s(id="edge-w-6--w-5")
    refute html =~ "flow-edge-active"
    assert html =~ "Model and Universe: 2 messages"
  end

  test "a lit pair takes its message's colour, shows it and moves a dot along it" do
    html = render([{"w:5", "w:6"}])

    [lit] =
      Regex.scan(~r/<g id="edge-w-6--w-5" class="[^"]*flow-edge-active[^"]*">.*?<\/g>/s, html)

    assert hd(lit) =~ "animateMotion"
    assert hd(lit) =~ "flow-pulse"
    # The dot runs the way the message went: from pg (#5) back to job (#6).
    assert hd(lit) =~ ~r/animateMotion[^>]*path="M 850 /
  end

  test "nodes are cards with a dot, a name and a kind; a worker's ID is muted" do
    html = render([])
    assert html =~ ~r/<tspan class="fill-base-content\/45">#6<\/tspan><tspan dx="4">job<\/tspan>/
    assert html =~ ~r/>\s*service\s*</
    # Each node is a clickable card in its kind's colour.
    assert html =~ ~r/<g id="node-w-5" class="flow-node[^"]*" phx-click="select"/
    assert html =~ ~s(class="flow-card stroke-success")
  end

  test "a line passes under other nodes, never under its own two" do
    html = render([])
    nodes = Map.new(graph().nodes, &{&1.key, &1})
    [mask] = Regex.run(~r/<mask id="mask-universe--w-5".*?<\/mask>/s, html)
    # The job (#6) sits on the way from Universe to pg (#5): the line goes under it.
    assert mask =~ ~s(y="#{nodes["w:6"].y - 10}")
    assert Regex.scan(~r/fill="black"/, mask) |> length() == 1
    assert html =~ ~s[<g mask="url(#mask-universe--w-5)">]
    # Neighbouring columns: nothing in between, so no mask at all.
    refute html =~ "mask-model--universe"
  end
end
