defmodule UniverseWeb.TopologyTest do
  use ExUnit.Case, async: true

  alias UniverseWeb.Topology

  defp ev(seq, type, id, data),
    do: %{
      "seq" => seq,
      "type" => type,
      "id" => id,
      "tick" => 1,
      "ts" => "2026-10-11T10:00:00Z",
      "data" => data
    }

  defp events do
    [
      ev(1, "tick_in", nil, %{"directives" => [%{"op" => "serve"}, %{"op" => "run"}]}),
      ev(2, "spawn", 5, %{"label" => "pg", "kind" => "serve", "lang" => "python"}),
      ev(3, "serve", 5, %{"name" => "pg"}),
      ev(4, "spawn", 6, %{"label" => "job", "kind" => "run", "lang" => "python"}),
      ev(5, "call", 6, %{"service" => "pg", "fn" => "q", "via" => "sdk"}),
      ev(6, "call_done", 6, %{"service" => "pg", "fn" => "q", "ok" => true}),
      ev(7, "call", 6, %{"service" => "pg", "fn" => "q", "via" => "sdk"}),
      ev(8, "call_done", 6, %{"service" => "pg", "fn" => "q", "ok" => true}),
      ev(9, "put", 6, %{"handle" => "h:6/x", "summary" => "1 row"}),
      ev(10, "tick_out", nil, %{"wake" => "settled", "tokens_out_est" => 9})
    ]
  end

  defp worker(5), do: %{label: "pg", kind: "serve", lang: "python"}
  defp worker(6), do: %{label: "job", kind: "run", lang: "python"}

  defp graph(live \\ %{}),
    do: Topology.build(events(), live, worker: &worker/1, owner: fn "pg", _ -> 5 end)

  test "one edge per direction, counting messages" do
    edges = Map.new(graph().edges, &{{&1.from, &1.to}, &1})

    assert edges[{"w:6", "w:5"}].count == 2
    assert edges[{"w:5", "w:6"}].count == 2
    assert edges[{"model", "universe"}].count == 1
    assert edges[{"universe", "model"}].count == 1
    assert edges[{"w:6", "handles"}].seq == 9
  end

  test "columns: model, Universe, runs, services, handles" do
    cols = Map.new(graph().nodes, &{&1.key, &1.col})
    assert cols == %{"model" => 0, "universe" => 1, "w:6" => 2, "w:5" => 3, "handles" => 4}
  end

  test "live workers without traffic still appear; status comes from the snapshot" do
    idle = %{
      id: 9,
      label: "helper",
      kind: "serve",
      status: "serving",
      spec: %{agent: %{model: "haiku"}, lang: "agent"}
    }

    nodes =
      Map.new(
        graph(%{9 => idle, 5 => %{idle | label: "pg", spec: %{lang: "python"}}}).nodes,
        &{&1.key, &1}
      )

    assert %{kind: :agent, col: 3, status: "serving"} = nodes["w:9"]
    assert nodes["w:5"].status == "serving"
    assert nodes["w:6"].status == "gone"
  end

  test "paths leave the right side toward later columns and bend apart by direction" do
    g = graph()
    n = Map.new(g.nodes, &{&1.key, &1})
    there = Topology.path(n["w:6"], n["w:5"])
    back = Topology.path(n["w:5"], n["w:6"])
    assert there =~ ~r/^M 674\.0 /
    assert there != back
  end

  test "a column keeps 12 workers, live first, then most recent; the rest fold into +N more" do
    spawns =
      for id <- 1..20,
          do: ev(id, "spawn", id, %{"label" => "r#{id}", "kind" => "run", "lang" => "bash"})

    live = %{3 => %{id: 3, label: "r3", kind: "run", status: "running", spec: %{lang: "bash"}}}

    g =
      Topology.build(spawns, live,
        worker: fn id -> %{label: "r#{id}", kind: "run", lang: "bash"} end,
        owner: fn _, _ -> nil end
      )

    runs = Enum.filter(g.nodes, &(&1.col == 2))

    assert length(runs) == 13
    assert "w:3" in Enum.map(runs, & &1.key)
    assert "w:20" in Enum.map(runs, & &1.key)
    refute "w:1" in Enum.map(runs, & &1.key)
    assert %{label: "+8 more"} = List.last(Enum.sort_by(runs, & &1.y))
    # No edge points at a node that was folded away.
    keys = MapSet.new(g.nodes, & &1.key)
    assert Enum.all?(g.edges, &(MapSet.member?(keys, &1.from) and MapSet.member?(keys, &1.to)))
  end

  test "busy windows keep the newest traffic (no row limit for the graph)" do
    old = for n <- 1..500, do: ev(n, "tick_in", nil, %{"directives" => []})
    newest = ev(501, "spawn", 77, %{"label" => "fresh", "kind" => "run", "lang" => "bash"})

    g =
      Topology.build(old ++ [newest], %{},
        worker: fn _ -> %{label: "fresh", kind: "run", lang: "bash"} end,
        owner: fn _, _ -> nil end
      )

    assert "w:77" in Enum.map(g.nodes, & &1.key)
    assert Enum.find(g.edges, &(&1.from == "model")).count == 500
  end
end
