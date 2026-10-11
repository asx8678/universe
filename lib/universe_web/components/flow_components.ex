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
  attr :active, :any, required: true, doc: "MapSet of {from, to} edges to animate"

  @doc "The live who-talks-to-whom graph (see `UniverseWeb.Topology`)."
  def topology(assigns) do
    nodes = Map.new(assigns.graph.nodes, &{&1.key, &1})
    {node_w, node_h} = UniverseWeb.Topology.node_size()

    edges =
      for e <- assigns.graph.edges,
          from = nodes[e.from],
          to = nodes[e.to],
          not is_nil(from) and not is_nil(to) do
        {mx, my} = UniverseWeb.Topology.midpoint(from, to)

        Map.merge(e, %{
          d: UniverseWeb.Topology.path(from, to),
          mx: mx,
          my: my,
          active: MapSet.member?(assigns.active, {e.from, e.to})
        })
      end

    assigns =
      assign(assigns,
        edges: edges,
        width: UniverseWeb.Topology.width(),
        node_w: node_w,
        node_h: node_h
      )

    ~H"""
    <svg
      id="topology"
      viewBox={"0 0 #{@width} #{@graph.height}"}
      class="block h-auto w-full font-sans"
      role="img"
      aria-label="Who talks to whom"
    >
      <g id="edges">
        <g
          :for={e <- @edges}
          id={"edge-" <> dom(e.from) <> "--" <> dom(e.to)}
          class={["flow-edge", e.active && "flow-edge-active"]}
        >
          <title>{e.count} message(s) · last: {e.label}</title>
          <path
            d={e.d}
            fill="none"
            class={[tone_stroke(e.tone), not e.active && "opacity-35", e.active && "flow-dash"]}
            stroke-width={edge_width(e.count)}
            stroke-linecap="round"
          />
          <circle :if={e.active} r="4" class={tone_fill(e.tone)}>
            <animateMotion dur="1.1s" repeatCount="indefinite" path={e.d} />
          </circle>
          <text
            :if={e.active}
            x={e.mx}
            y={e.my - 14}
            text-anchor="middle"
            class={["text-[12px] font-medium", tone_fill(e.tone)]}
          >
            {fit(e.label, 240)} · {e.count}×
          </text>
        </g>
      </g>

      <g id="nodes">
        <g :for={n <- @graph.nodes} id={"node-" <> dom(n.key)}>
          <title>{n.label} · {n.sub}{if n.status, do: " · #{n.status}"}</title>
          <%!-- An opaque base, so edges pass behind nodes instead of through them. --%>
          <rect
            x={n.x - @node_w / 2}
            y={n.y - @node_h / 2}
            width={@node_w}
            height={@node_h}
            rx="12"
            class="fill-base-100"
          />
          <rect
            x={n.x - @node_w / 2}
            y={n.y - @node_h / 2}
            width={@node_w}
            height={@node_h}
            rx="12"
            class={[lane_class(n.kind), n.status == "gone" && "opacity-40"]}
            stroke-width="1.3"
          />
          <circle
            :if={n.status}
            cx={n.x - @node_w / 2 + 12}
            cy={n.y - 6}
            r="3.5"
            class={status_dot(n.status)}
          />
          <text
            x={n.x}
            y={n.y - 2}
            text-anchor="middle"
            class="fill-base-content text-[12px] font-semibold"
          >
            {fit(n.label, @node_w - 30)}
          </text>
          <text x={n.x} y={n.y + 13} text-anchor="middle" class="fill-base-content/60 text-[11px]">
            {fit(
              n.sub <> if(n.status && n.status != "gone", do: " · #{n.status}", else: ""),
              @node_w - 16
            )}
          </text>
        </g>
      </g>
    </svg>
    """
  end

  defp dom(key), do: key |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.trim("-")

  defp edge_width(count), do: Float.round(1.4 + :math.log2(count) * 0.7, 1)

  defp status_dot("serving"), do: "fill-success"
  defp status_dot("asking"), do: "fill-warning"
  defp status_dot(s) when s in ["running", "queued"], do: "fill-info animate-pulse"
  defp status_dot("gone"), do: "fill-base-content/30"
  defp status_dot(_), do: "fill-base-content/50"

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
