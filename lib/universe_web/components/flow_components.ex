defmodule UniverseWeb.FlowComponents do
  @moduledoc """
  Server-rendered SVG for flow diagrams: `sequence_diagram/1` draws a
  `UniverseWeb.Flow.diagram/2` result (lanes as lifelines, messages as
  arrows, folded output as notes). Colours come from the theme, so it follows
  light and dark mode; long labels are clipped with the full text in a
  tooltip.
  """

  use Phoenix.Component

  # Lanes shrink from 190 px to fit the page (about 7 lanes); below 150 px
  # the diagram scrolls sideways instead.
  @lane_w 190
  @min_lane_w 150
  @fit_width 1130
  @left 64
  @header_h 56
  @row_h 30
  @char_w 6.3

  attr :diagram, :map, required: true
  attr :id, :string, default: "sequence"

  def sequence_diagram(assigns) do
    lanes = assigns.diagram.lanes
    index = lanes |> Enum.with_index() |> Map.new(fn {l, i} -> {l.key, i} end)
    rows = Enum.with_index(assigns.diagram.rows)
    lw = lane_width(length(lanes))
    width = @left + length(lanes) * lw + 12
    height = @header_h + 18 + length(assigns.diagram.rows) * @row_h + 24

    assigns =
      assign(assigns,
        lane_w: lw,
        header_h: @header_h,
        left: @left,
        lanes: Enum.with_index(lanes),
        index: index,
        rows: rows,
        width: width,
        height: height,
        bottom: height - 12
      )

    ~H"""
    <div class="overflow-x-auto rounded-xl border border-base-300 bg-base-100">
      <svg
        id={@id}
        viewBox={"0 0 #{@width} #{@height}"}
        width={@width}
        height={@height}
        class="block font-sans"
        role="img"
        aria-label="Sequence diagram of the tick"
      >
        <%!-- Lifelines and lane headers --%>
        <g :for={{lane, i} <- @lanes} id={"lane-#{lane.key}"}>
          <line
            x1={x(i, @lane_w)}
            y1={@header_h - 4}
            x2={x(i, @lane_w)}
            y2={@bottom}
            class="stroke-base-content/15"
            stroke-dasharray="3 4"
          />
          <rect
            x={x(i, @lane_w) - @lane_w / 2 + 8}
            y="8"
            width={@lane_w - 16}
            height={@header_h - 18}
            rx="10"
            class={lane_class(lane.kind)}
            stroke-width="1.2"
          />
          <text
            x={x(i, @lane_w)}
            y="27"
            text-anchor="middle"
            class="fill-base-content text-[12px] font-semibold"
          >
            <title>{lane.label}</title>
            {fit(lane.label, @lane_w - 28)}
          </text>
          <text x={x(i, @lane_w)} y="41" text-anchor="middle" class="fill-base-content/60 text-[11px]">
            {lane.sub}
          </text>
        </g>

        <%!-- Rows --%>
        <g :for={{row, n} <- @rows} id={"row-#{n}"} class={"flow-row flow-#{row.type}"}>
          <text
            :if={row.at != ""}
            x="8"
            y={y(n) + 4}
            class="fill-base-content/55 text-[11px] tabular-nums"
          >
            {row.at}
          </text>
          <%= case row.type do %>
            <% :msg -> %>
              <.arrow row={row} from={@index[row.from]} to={@index[row.to]} y={y(n)} lane_w={@lane_w} />
            <% :note -> %>
              <.note row={row} lane={@index[row.lane]} y={y(n)} lane_w={@lane_w} />
            <% :divider -> %>
              <line
                x1={@left - 4}
                y1={y(n)}
                x2={@width - 8}
                y2={y(n)}
                class="stroke-base-content/25"
                stroke-dasharray="6 4"
              />
              <text x={@left} y={y(n) - 5} class="fill-base-content/50 text-[11px] italic">
                {row.label}
              </text>
          <% end %>
        </g>
      </svg>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :from, :integer, required: true
  attr :to, :integer, required: true
  attr :y, :any, required: true
  attr :lane_w, :integer, required: true

  defp arrow(%{from: from, to: to} = assigns) when from == to do
    # A lane talking to itself: a small loop.
    assigns = assign(assigns, x: x(from, assigns.lane_w))

    ~H"""
    <path
      d={"M #{@x} #{@y - 6} h 26 v 12 h -20"}
      fill="none"
      class={tone_stroke(@row.tone)}
      stroke-width="1.4"
      stroke-dasharray={if @row.dashed, do: "5 4"}
    />
    <text x={@x + 32} y={@y + 4} class={["text-[12px]", tone_fill(@row.tone)]}>
      <title>{@row.label}</title>
      {fit(@row.label, @lane_w - 40)}
    </text>
    """
  end

  defp arrow(assigns) do
    lw = assigns.lane_w
    x1 = x(assigns.from, lw)
    x2 = x(assigns.to, lw)
    dir = if x2 > x1, do: 1, else: -1
    tip = x2 - dir * 2

    assigns =
      assign(assigns,
        x1: x1 + dir * 2,
        x2: tip - dir * 7,
        tip: tip,
        head:
          "#{tip},#{assigns.y} #{tip - dir * 8},#{assigns.y - 4.5} #{tip - dir * 8},#{assigns.y + 4.5}",
        # One message per row, so a label may run past its arrow: start it
        # at the left end and give it at least two lanes of room.
        label_x: min(x1, x2) + 10,
        room: max(abs(x2 - x1) - 16, lw * 2.2)
      )

    ~H"""
    <line
      x1={@x1}
      y1={@y}
      x2={@x2}
      y2={@y}
      class={tone_stroke(@row.tone)}
      stroke-width="1.4"
      stroke-dasharray={if @row.dashed, do: "5 4"}
    />
    <polygon points={@head} class={tone_fill(@row.tone)} />
    <text x={@label_x} y={@y - 6} class={["text-[12px]", tone_fill(@row.tone)]}>
      <title>{@row.label}</title>
      {fit(@row.label, @room)}
    </text>
    """
  end

  attr :row, :map, required: true
  attr :lane, :integer, required: true
  attr :y, :any, required: true
  attr :lane_w, :integer, required: true

  defp note(assigns) do
    label =
      if assigns.row.count > 1,
        do: "#{assigns.row.label} ×#{assigns.row.count}",
        else: assigns.row.label

    assigns = assign(assigns, x: x(assigns.lane, assigns.lane_w), label: label)

    ~H"""
    <rect
      x={@x - @lane_w / 2 + 12}
      y={@y - 10}
      width={@lane_w - 24}
      height="20"
      rx="6"
      class={note_class(@row.tone)}
    />
    <text x={@x} y={@y + 4} text-anchor="middle" class="fill-base-content/80 text-[11px] font-mono">
      <title>{@label}</title>
      {fit(@label, @lane_w - 34)}
    </text>
    """
  end

  attr :graph, :map, required: true

  attr :active, :any,
    required: true,
    doc: "MapSet of {from, to} edges that just carried a message"

  attr :selected, :string, default: nil, doc: "key of the clicked node, if any"

  @doc """
  The live who-talks-to-whom graph (see `UniverseWeb.Topology`): each node a
  dot in its kind's colour with its name below, one hairline per pair of
  nodes that talked. While a pair is in `active` its line takes the colour
  of the message, a dot travels the way it went and the message shows.

  A line is masked where it crosses another node's dot and name, so it
  passes under that node instead of seeming to connect to it. Only nodes it
  can cross get masked: those in the columns between its ends (or, for a
  loop within a column, the rows between).
  """
  def topology(assigns) do
    nodes = Map.new(assigns.graph.nodes, &{&1.key, &1})
    views = Enum.map(assigns.graph.nodes, &node_view/1)

    links =
      assigns.graph.edges
      |> Enum.filter(&(nodes[&1.from] && nodes[&1.to] && &1.from != &1.to))
      |> Enum.group_by(&pair(nodes[&1.from], nodes[&1.to]))
      |> Enum.map(fn {{a, b}, edges} ->
        nodes[a]
        |> link(nodes[b], edges, assigns.active)
        |> Map.put(:under, under(views, nodes[a], nodes[b]))
      end)
      # Lit lines last, so they draw over quiet ones.
      |> Enum.sort_by(& &1.active)

    sel = assigns.selected
    links = Enum.map(links, &Map.put(&1, :focus, sel && (&1.a == sel or &1.b == sel)))

    # Only as wide as the columns in use, so the graph stays large beside
    # the details panel.
    {x0, x1} =
      case Enum.map(views, & &1.x) do
        [] -> {0, UniverseWeb.Topology.width()}
        xs -> {max(Enum.min(xs) - 96, 0), min(Enum.max(xs) + 130, UniverseWeb.Topology.width())}
      end

    assigns =
      assign(assigns,
        links: links,
        nodes: views,
        width: UniverseWeb.Topology.width(),
        x0: x0,
        view_w: x1 - x0
      )

    ~H"""
    <svg
      id="topology"
      viewBox={"#{@x0} 0 #{@view_w} #{@graph.height}"}
      width={@view_w}
      height={@graph.height}
      class="block h-auto max-w-full font-sans"
      role="img"
      aria-label="Who talks to whom"
    >
      <defs>
        <mask
          :for={l <- @links}
          :if={l.under != []}
          id={"mask-" <> l.dom}
          maskUnits="userSpaceOnUse"
          x="0"
          y="0"
          width={@width}
          height={@graph.height}
        >
          <rect x="0" y="0" width={@width} height={@graph.height} fill="white" />
          <rect
            :for={n <- l.under}
            x={n.fx}
            y={n.fy}
            width={n.fw}
            height={n.fh}
            rx="6"
            fill="black"
          />
        </mask>
      </defs>

      <g id="edges">
        <g
          :for={l <- @links}
          id={"edge-" <> l.dom}
          class={[
            "flow-edge transition-opacity duration-300",
            l.active && "flow-edge-active",
            @selected && !l.focus && !l.active && "opacity-25"
          ]}
        >
          <title>{l.title}</title>
          <g mask={l.under != [] && "url(#mask-#{l.dom})"}>
            <path
              d={l.d}
              fill="none"
              class={["transition-[stroke]", line_class(l)]}
              stroke-width={l.width}
              stroke-linecap="round"
            />
            <circle :if={l.active} r="2.5" class={["flow-pulse", tone_fill(l.tone)]}>
              <animateMotion dur="1.2s" repeatCount="indefinite" path={l.travel} />
            </circle>
          </g>
          <text
            :if={l.active}
            x={l.mx}
            y={l.my - 9}
            text-anchor="middle"
            class={["flow-label text-[11px]", tone_fill(l.tone)]}
          >
            {fit(l.label, 240)}
          </text>
        </g>
      </g>

      <g id="nodes">
        <g
          :for={n <- @nodes}
          id={"node-" <> dom(n.key)}
          class={["flow-node", n.gone && "opacity-50", @selected == n.key && "flow-node-selected"]}
          phx-click="select"
          phx-keydown="select"
          phx-key="Enter"
          phx-value-key={n.key}
          role="button"
          tabindex="0"
          aria-label={"Show details of " <> n.title}
          aria-pressed={to_string(@selected == n.key)}
        >
          <title>{n.title}</title>
          <%!-- A soft card: brighter on hover, outlined in the node's colour when selected. --%>
          <rect
            x={n.fx}
            y={n.fy - 4}
            width={n.fw}
            height={n.fh + 2}
            rx="10"
            class={["flow-card", n.ring]}
          />
          <%!-- A disc in the card colour, so lines stop short of the dot. --%>
          <circle cx={n.x} cy={n.y} r="9" class="flow-disc" />
          <circle
            :if={n.asking}
            cx={n.x}
            cy={n.y}
            r="8"
            fill="none"
            class="stroke-warning"
            stroke-width="1.5"
          />
          <circle cx={n.x} cy={n.y} r="4.5" class={["flow-dot", n.dot]} />
          <%!-- No whitespace inside: SVG would draw it as a gap. --%>
          <text
            x={n.x}
            y={n.y + 24}
            text-anchor="middle"
            class="flow-label fill-base-content text-[12px] font-medium"
            phx-no-format
          ><tspan :if={n.id} class="fill-base-content/45">{n.id}</tspan><tspan dx={n.id && "4"}>{n.name}</tspan></text>
          <text
            x={n.x}
            y={n.y + 39}
            text-anchor="middle"
            class={["flow-label text-[11px]", n.sub_class]}
            phx-no-format
          >{n.sub}</text>
        </g>
      </g>
    </svg>
    """
  end

  # Two nodes' line, keyed left to right (by column, then key).
  defp pair(a, b),
    do: if({a.col, a.key} <= {b.col, b.key}, do: {a.key, b.key}, else: {b.key, a.key})

  # Both directions between a pair as one line; the newest lit direction
  # (else the newest overall) gives the colour, the label and the way the
  # dot travels.
  defp link(a, b, edges, active) do
    lit = Enum.filter(edges, &MapSet.member?(active, {&1.from, &1.to}))
    shown = Enum.max_by(if(lit == [], do: edges, else: lit), & &1.seq)
    count = edges |> Enum.map(& &1.count) |> Enum.sum()
    {mx, my} = UniverseWeb.Topology.midpoint(a, b)
    {from, to} = if shown.from == a.key, do: {a, b}, else: {b, a}

    %{
      a: a.key,
      b: b.key,
      dom: dom(a.key) <> "--" <> dom(b.key),
      d: UniverseWeb.Topology.curve(a, b),
      travel: UniverseWeb.Topology.curve(from, to),
      active: lit != [],
      tone: shown.tone,
      label: shown.label,
      width: Float.round(min(1.0 + :math.log2(count) * 0.3, 2.4), 2),
      mx: mx,
      my: my,
      title:
        "#{a.label} and #{b.label}: #{count} #{plural(count, "message")}, last: #{shown.label}"
    }
  end

  # The nodes a pair's line can cross: those in the columns strictly between
  # its ends, or for a loop within one column the rows between. Lines leave
  # and reach a dot level, so nodes beside an end are never in the way.
  defp under(views, a, b) do
    if a.col == b.col do
      {lo, hi} = Enum.min_max([a.y, b.y])
      Enum.filter(views, &(&1.col == a.col and &1.y > lo and &1.y < hi))
    else
      {lo, hi} = Enum.min_max([a.col, b.col])
      Enum.filter(views, &(&1.col > lo and &1.col < hi))
    end
  end

  defp line_class(%{active: true, tone: tone}), do: tone_stroke(tone)
  defp line_class(%{focus: true}), do: "stroke-base-content/55"
  defp line_class(_link), do: "stroke-base-content/20"

  defp node_view(n) do
    {id, name} =
      case Regex.run(~r/^(#\d+) (.+)$/, n.label) do
        [_, id, name] -> {id, name}
        _ -> {nil, n.label}
      end

    name = fit(name, if(id, do: 120, else: 150))
    sub = if(n.status == "asking", do: "asking", else: kind_word(n))
    # The dot and both lines of text: what other nodes' lines pass under.
    footprint =
      Enum.max([
        String.length(name) * 7 + if(id, do: String.length(id) * 7 + 4, else: 0),
        String.length(sub) * 6.3,
        64
      ]) + 16

    %{
      key: n.key,
      x: n.x,
      y: n.y,
      col: n.col,
      fx: n.x - footprint / 2,
      fy: n.y - 10,
      fw: footprint,
      fh: 56,
      id: id,
      name: name,
      sub: sub,
      sub_class: if(n.status == "asking", do: "fill-warning", else: "fill-base-content/50"),
      dot: dot_class(n),
      ring: kind_stroke(n.kind),
      asking: n.status == "asking",
      gone: n.status == "gone",
      title: Enum.join([n.label, n.sub, n.status] |> Enum.reject(&is_nil/1), ", ")
    }
  end

  defp kind_word(%{more: true} = n), do: n.sub
  defp kind_word(%{kind: :model}), do: "Claude Code"
  defp kind_word(%{kind: :universe}), do: "kernel"
  defp kind_word(%{kind: :handles}), do: "stored data"
  defp kind_word(%{kind: :run}), do: "run"
  defp kind_word(%{kind: kind}), do: Atom.to_string(kind)

  defp dot_class(%{more: true}), do: "fill-base-100 stroke-base-content/40"

  defp dot_class(n) do
    [kind_fill(n.kind), n.status in ["running", "queued"] && "motion-safe:animate-pulse"]
  end

  defp kind_stroke(:model), do: "stroke-primary"
  defp kind_stroke(:universe), do: "stroke-base-content/60"
  defp kind_stroke(:agent), do: "stroke-accent"
  defp kind_stroke(:service), do: "stroke-success"
  defp kind_stroke(:handles), do: "stroke-warning"
  defp kind_stroke(_), do: "stroke-info"

  defp kind_fill(:model), do: "fill-primary"
  defp kind_fill(:universe), do: "fill-base-content/70"
  defp kind_fill(:agent), do: "fill-accent"
  defp kind_fill(:service), do: "fill-success"
  defp kind_fill(:handles), do: "fill-warning"
  defp kind_fill(_), do: "fill-info"

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  defp dom(key), do: key |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.trim("-")

  defp x(i, lw), do: @left + i * lw + lw / 2

  defp lane_width(n) when n > 0,
    do: (@fit_width - @left) |> div(n) |> min(@lane_w) |> max(@min_lane_w)

  defp lane_width(_), do: @lane_w
  defp y(n), do: @header_h + 18 + n * @row_h + @row_h / 2

  @doc false
  # Clips text to roughly `px` pixels of 11px sans.
  def fit(text, px) do
    max = max(trunc(px / @char_w), 6)
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp lane_class(:model), do: "fill-primary/15 stroke-primary/60"
  defp lane_class(:universe), do: "fill-base-content/10 stroke-base-content/40"
  defp lane_class(:agent), do: "fill-accent/15 stroke-accent/60"
  defp lane_class(:service), do: "fill-success/15 stroke-success/60"
  defp lane_class(:handles), do: "fill-warning/15 stroke-warning/60"
  defp lane_class(_), do: "fill-info/15 stroke-info/60"

  defp tone_stroke(:model), do: "stroke-primary"
  defp tone_stroke(:good), do: "stroke-success"
  defp tone_stroke(:bad), do: "stroke-error"
  defp tone_stroke(:warn), do: "stroke-warning"
  defp tone_stroke(:info), do: "stroke-info"
  defp tone_stroke(_), do: "stroke-base-content/40"

  defp tone_fill(:model), do: "fill-primary"
  defp tone_fill(:good), do: "fill-success"
  defp tone_fill(:bad), do: "fill-error"
  defp tone_fill(:warn), do: "fill-warning"
  defp tone_fill(:info), do: "fill-info"
  defp tone_fill(_), do: "fill-base-content/60"

  defp note_class(:bad), do: "fill-error/10 stroke-error/40"
  defp note_class(:warn), do: "fill-warning/10 stroke-warning/40"
  defp note_class(_), do: "fill-base-200 stroke-base-content/15"
end
