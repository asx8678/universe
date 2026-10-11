defmodule UniverseWeb.FlowTest do
  use ExUnit.Case, async: true

  alias UniverseWeb.Flow

  # A small story: the model starts a service and a snippet; the snippet
  # stores a handle, reads it back and calls the service; an agent asks.
  defp events do
    [
      ev(1, "tick_in", nil, %{
        "directives" => [%{"op" => "serve"}, %{"op" => "run"}, %{"op" => "call"}]
      }),
      ev(2, "spawn", 5, %{"label" => "pg", "kind" => "serve", "lang" => "python"}),
      ev(3, "serve", 5, %{"name" => "pg", "fns" => ["query"]}),
      ev(4, "spawn", 6, %{"label" => "job", "kind" => "run", "lang" => "python"}),
      ev(5, "stdout", 6, %{"text" => "one\n"}),
      ev(6, "stdout", 6, %{"text" => "two\n"}),
      ev(7, "put", 6, %{"handle" => "h:6/rows", "summary" => "3 rows"}),
      ev(8, "get", 6, %{"handle" => "h:6/rows", "ok" => true}),
      ev(9, "call", 6, %{"service" => "pg", "fn" => "query", "via" => "sdk"}),
      ev(10, "call_done", 6, %{"service" => "pg", "fn" => "query", "ok" => true, "wall_ms" => 12}),
      ev(11, "call", 7, %{"service" => "pg", "fn" => "query", "via" => "tick"}),
      ev(12, "exit", 7, %{"status" => "done", "result_text" => ~s("42")}),
      ev(13, "exit", 6, %{"status" => "done", "wall_ms" => 900, "last_out" => "two"}),
      ev(14, "ask", 6, %{"question" => "which?"}),
      ev(15, "tick_out", nil, %{"wake" => "settled", "tokens_out_est" => 80}),
      ev(16, "stdout", 5, %{"text" => "late\n"})
    ]
  end

  defp ev(seq, type, id, data),
    do: %{
      "seq" => seq,
      "type" => type,
      "id" => id,
      "tick" => 1,
      "ts" => "2026-10-11T10:00:0#{rem(seq, 10)}Z",
      "data" => data
    }

  defp worker(5), do: %{label: "pg", kind: "serve", lang: "python"}
  defp worker(6), do: %{label: "job", kind: "run", lang: "python"}
  defp worker(7), do: %{label: "q", kind: "call", lang: nil}
  defp worker(_), do: %{label: "?", kind: "run", lang: nil}

  defp diagram, do: Flow.diagram(events(), worker: &worker/1, owner: fn "pg", _ -> 5 end)

  defp msgs(d), do: for(%{type: :msg} = r <- d.rows, do: {r.from, r.to, r.label})

  test "lanes: model, Universe, workers in order of appearance, then handles" do
    assert Enum.map(diagram().lanes, & &1.key) == ["model", "universe", "w:5", "w:6", "handles"]
    assert Enum.map(diagram().lanes, & &1.kind) == [:model, :universe, :service, :run, :handles]
  end

  test "every flow becomes an arrow between the right lanes" do
    m = msgs(diagram())

    assert {"model", "universe", "tick t1: 1 serve, 1 run, 1 call"} in m
    assert {"universe", "w:5", "start serve (python)"} in m
    assert {"w:5", "universe", "serving pg"} in m
    assert {"w:6", "handles", "store h:6/rows (3 rows)"} in m
    assert {"handles", "w:6", "read h:6/rows"} in m
    assert {"w:6", "w:5", "call query"} in m
    assert {"w:5", "w:6", "answer · 12ms"} in m
    # A call directive goes through Universe; its call ID is not a lane.
    assert {"universe", "w:5", "call query"} in m
    assert {"w:5", "universe", "answer: 42"} in m
    assert {"w:6", "universe", "exit done · 900ms · two"} in m
    assert {"w:6", "model", "asks: which?"} in m
    assert {"universe", "model", "digest · settled · ~80 tokens"} in m
  end

  test "answers are dashed, requests solid" do
    rows = diagram().rows
    assert Enum.find(rows, &(&1[:label] == "answer · 12ms")).dashed
    refute Enum.find(rows, &(&1[:label] == "call query")).dashed
  end

  test "output folds into one note per lane until the lane talks; a divider follows the digest" do
    d = diagram()
    notes = for %{type: :note} = r <- d.rows, do: {r.lane, r.label, r.count}

    assert {"w:6", "two", 2} in notes
    assert {"w:5", "late", 1} in notes
    assert d.folded == 1

    i_digest = Enum.find_index(d.rows, &(&1[:label] == "digest · settled · ~80 tokens"))
    assert %{type: :divider} = Enum.at(d.rows, i_digest + 1)
  end

  test "agent lanes skip busy/idle progress and per-task log lines" do
    events = [
      ev(1, "spawn", 9, %{"label" => "rev", "kind" => "serve", "lang" => "agent"}),
      ev(2, "progress", 9, %{"text" => "busy · task 1"}),
      ev(3, "stdout", 9, %{"text" => "task 1 done\n"}),
      ev(4, "stderr", 9, %{"text" => "boom\n"})
    ]

    d =
      Flow.diagram(events,
        worker: fn _ -> %{label: "rev", kind: "serve", lang: "agent"} end,
        owner: fn _, _ -> nil end
      )

    assert [{"w:9", "boom"}] == for(%{type: :note} = r <- d.rows, do: {r.lane, r.label})
    assert Enum.find(d.lanes, &(&1.key == "w:9")).kind == :agent
  end
end
