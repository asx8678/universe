defmodule UniverseWeb.Topology do
  @moduledoc """
  Who talks to whom, as a graph: nodes for the model, Universe (the
  kernel), runs, services and agents, and the handle store; one edge per
  direction between two nodes, with how many messages crossed it, when the
  last one did (event `seq`) and what it said.

  Messages come from `UniverseWeb.Flow.diagram/2` over a window of recent
  events, so this graph and the per-tick sequence diagrams always agree.
  Live workers without recent traffic (an idle agent) are nodes too.

  Layout is fixed columns, left to right: model, Universe, runs, services and
  agents, handles. Pure apart from the default lookups.
  """

  alias UniverseWeb.Flow

  @width 1120
  # A node is a dot with two lines of text below it.
  @node_h 44
  @gap 16
  @top 30
  @cols %{model: 0, universe: 1, run: 2, service: 3, agent: 3, handles: 4}
  @col_x [96, 330, 590, 850, 1030]
  @live ~w(queued running serving asking)
  # Worker nodes per column; the rest fold into one "+N more" node.
  @max_per_col 12

  def width, do: @width

  @doc """
  The graph for `events`, adding `live` workers (`%{id => worker}` from
  `Tick.snapshot/0`) that have no traffic in the window.
  """
  def build(events, live \\ %{}, opts \\ []) do
    # Every message in the window, the newest included; no notes needed here.
    d = Flow.diagram(events, Keyword.merge([max_rows: :infinity, notes: false], opts))

    lanes = Map.new(d.lanes, &{&1.key, &1})

    lanes =
      Enum.reduce(live, lanes, fn {id, w}, acc ->
        key = "w:#{id}"

        if w.status in @live and w.kind != "call" and not Map.has_key?(acc, key),
          do: Map.put(acc, key, lane_for(id, w)),
          else: acc
      end)

    edges =
      for %{type: :msg} = r <- d.rows, reduce: %{} do
        acc ->
          Map.update(
            acc,
            {r.from, r.to},
            %{from: r.from, to: r.to, count: 1, seq: r.seq, label: r.label, tone: r.tone},
            &%{&1 | count: &1.count + 1, seq: max(&1.seq, r.seq), label: r.label, tone: r.tone}
          )
      end
      |> Map.values()

    # Model and Universe are always there, even before the first tick.
    lanes =
      lanes
      |> Map.put_new("model", %{key: "model", label: "Model", sub: "Claude Code", kind: :model})
      |> Map.put_new("universe", %{
        key: "universe",
        label: "Universe",
        sub: "Tick · kernel",
        kind: :universe
      })

    {lanes, edges} = cap_columns(Map.values(lanes), edges, live)
    nodes = layout(lanes, live)
    recent = for(%{type: :msg} = r <- d.rows, do: r) |> Enum.take(-14) |> Enum.reverse()
    %{nodes: nodes, edges: edges, height: height(nodes), recent: recent}
  end

  defp lane_for(id, w) do
    {sub, kind} =
      cond do
        match?(%{agent: %{}}, w.spec) -> {"agent", :agent}
        w.kind == "serve" -> {"service · #{w.spec[:lang]}", :service}
        true -> {"#{w.kind} · #{w.spec[:lang]}", :run}
      end

    %{key: "w:#{id}", label: "##{id} #{w.label}", sub: sub, kind: kind}
  end

  # Keeps at most @max_per_col workers per column: live ones first, then the
  # most recently active. Edges to dropped nodes go too.
  defp cap_columns(lanes, edges, live) do
    last_seq =
      Enum.reduce(edges, %{}, fn e, acc ->
        acc
        |> Map.update(e.from, e.seq, &max(&1, e.seq))
        |> Map.update(e.to, e.seq, &max(&1, e.seq))
      end)

    {workers, fixed} = Enum.split_with(lanes, &(Map.get(@cols, &1.kind, 2) in [2, 3]))

    kept =
      workers
      |> Enum.group_by(&Map.get(@cols, &1.kind, 2))
      |> Enum.flat_map(fn {col, in_col} ->
        ranked =
          Enum.sort_by(in_col, fn l -> {not live?(l.key, live), -Map.get(last_seq, l.key, 0)} end)

        {shown, rest} = Enum.split(ranked, @max_per_col)

        if rest == [],
          do: shown,
          else:
            shown ++
              [
                %{
                  key: "more:#{col}",
                  label: "+#{length(rest)} more",
                  sub: "older workers",
                  kind: if(col == 2, do: :run, else: :service),
                  more: true
                }
              ]
      end)

    keys = MapSet.new(fixed ++ kept, & &1.key)

    {fixed ++ kept,
     Enum.filter(edges, &(MapSet.member?(keys, &1.from) and MapSet.member?(keys, &1.to)))}
  end

  defp live?("w:" <> id, live),
    do: match?(%{status: s} when s in @live, live[String.to_integer(id)])

  defp live?(_key, _live), do: false

  ## Layout

  defp layout(lanes, live) do
    lanes
    |> Enum.group_by(&Map.get(@cols, &1.kind, 2))
    |> Enum.flat_map(fn {col, in_col} ->
      in_col
      |> Enum.sort_by(&order/1)
      |> Enum.with_index()
      |> Enum.map(fn {lane, i} ->
        Map.merge(lane, %{
          x: Enum.at(@col_x, col),
          y: @top + i * (@node_h + @gap) + @node_h / 2,
          col: col,
          status: status(lane.key, live)
        })
      end)
    end)
    |> center()
  end

  # Newest workers at the bottom of their column, "+N more" last.
  defp order(%{key: "w:" <> id}), do: {0, String.to_integer(id)}
  defp order(%{key: key}), do: {1, key}

  # Every column sits centred as a block, so a short one lines up with the
  # model and Universe instead of hanging from the top.
  defp center(nodes) do
    h = height(nodes)
    counts = Enum.frequencies_by(nodes, & &1.col)

    Enum.map(nodes, fn n ->
      %{n | y: n.y + (h - (counts[n.col] * (@node_h + @gap) + @top * 2)) / 2}
    end)
  end

  defp height(nodes) do
    rows = nodes |> Enum.frequencies_by(& &1.col) |> Map.values() |> Enum.max(fn -> 1 end)
    max(rows * (@node_h + @gap) + @top * 2, 180)
  end

  defp status("more:" <> _, _live), do: nil

  defp status("w:" <> id, live) do
    case live[String.to_integer(id)] do
      nil -> "gone"
      w -> w.status
    end
  end

  defp status(_key, _live), do: nil

  ## Geometry for the view

  @doc """
  An SVG curve from node `a`'s dot to node `b`'s: a horizontal S between
  columns, a loop out to the right within one. Both directions between a
  pair share it; `curve(b, a)` is the same line run backwards.
  """
  def curve(a, b) do
    if a.col == b.col do
      "M #{a.x} #{a.y} C #{a.x + 70} #{a.y}, #{b.x + 70} #{b.y}, #{b.x} #{b.y}"
    else
      dx = (b.x - a.x) * 0.5
      "M #{a.x} #{a.y} C #{a.x + dx} #{a.y}, #{b.x - dx} #{b.y}, #{b.x} #{b.y}"
    end
  end

  @doc "The middle of `curve(a, b)`, where a lit line shows its message."
  def midpoint(a, b) do
    if a.col == b.col,
      do: {a.x + 52, (a.y + b.y) / 2},
      else: {(a.x + b.x) / 2, (a.y + b.y) / 2}
  end
end
