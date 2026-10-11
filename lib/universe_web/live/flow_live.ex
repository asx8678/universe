defmodule UniverseWeb.FlowLive do
  @moduledoc """
  Who talks to whom, live: the model, Universe, runs, services, agents and
  the handle store as a graph (`UniverseWeb.Topology`), one line per pair
  that talked in the recent window. A line with new traffic lights up for
  two seconds with its last message (its tooltip has the count). Clicking a
  node opens its details beside the graph: what it is, what it is doing and
  who it talks to, kept live. Below, the latest messages as text.
  """

  use UniverseWeb, :live_view

  import UniverseWeb.FlowComponents

  alias Universe.{EventLog, Handles, Tick}
  alias UniverseWeb.Topology

  # The graph covers the last window_s seconds (at most @max_events events).
  @max_events 2000
  @windows [60, 300, 1800]
  @refresh_ms 200
  @pulse_ms 2000

  @impl true
  # `?node=w:5` opens with that node's details shown.
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Universe.PubSub, EventLog.topic())
      :timer.send_interval(500, :expire)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Flow",
       pending: false,
       pulses: %{},
       seen: EventLog.last_seq(),
       window_s: 300,
       # The handles node's summary, read from disk only when a put came.
       handles: nil,
       selected: if(is_binary(params["node"]), do: params["node"])
     )
     |> load(false)}
  end

  @impl true
  # Clicking the selected node again closes its details.
  def handle_event("select", %{"key" => key}, socket) do
    selected = if socket.assigns.selected == key, do: nil, else: key
    {:noreply, socket |> assign(:selected, selected) |> with_details()}
  end

  def handle_event("deselect", _params, socket),
    do: {:noreply, socket |> assign(:selected, nil) |> with_details()}

  def handle_event("window", %{"s" => s}, socket) do
    window = Enum.find(@windows, 300, &(Integer.to_string(&1) == s))
    {:noreply, socket |> assign(:window_s, window) |> load(false)}
  end

  @impl true
  def handle_info({:event, _}, %{assigns: %{pending: true}} = socket), do: {:noreply, socket}

  def handle_info({:event, _}, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, :pending, true)}
  end

  def handle_info(:refresh, socket),
    do: {:noreply, socket |> assign(:pending, false) |> load(true)}

  def handle_info(:expire, %{assigns: %{pulses: pulses}} = socket) when map_size(pulses) == 0,
    do: {:noreply, socket}

  def handle_info(:expire, socket) do
    now = now()
    pulses = Map.reject(socket.assigns.pulses, fn {_, until} -> until <= now end)
    {:noreply, assign(socket, pulses: pulses, active: MapSet.new(Map.keys(pulses)))}
  end

  defp load(socket, pulse?) do
    last = EventLog.last_seq()
    cutoff = DateTime.add(DateTime.utc_now(), -socket.assigns.window_s, :second)

    events =
      EventLog.since(max(last - @max_events, 0))
      |> Enum.filter(&recent?(&1, cutoff))

    live =
      try do
        Tick.snapshot()
      catch
        :exit, _ -> %{}
      end

    graph = Topology.build(events, live)
    now = now()

    # Edges whose newest message arrived since the last render light up.
    fresh =
      if pulse?,
        do:
          for(
            e <- graph.edges,
            e.seq > socket.assigns.seen,
            into: %{},
            do: {{e.from, e.to}, now + @pulse_ms}
          ),
        else: %{}

    pulses = Map.merge(socket.assigns.pulses, fresh)
    put? = Enum.any?(events, &(&1["seq"] > socket.assigns.seen and &1["type"] == "put"))

    socket
    |> then(&if(put?, do: assign(&1, :handles, nil), else: &1))
    |> assign(
      graph: graph,
      live: live,
      pulses: pulses,
      active: MapSet.new(Map.keys(pulses)),
      seen: last,
      window: length(events)
    )
    |> with_details()
  end

  ## Details of the selected node

  # A selected node that left the graph (its window passed) closes.
  defp with_details(%{assigns: %{selected: nil}} = socket), do: assign(socket, :details, nil)

  defp with_details(socket) do
    %{selected: key, graph: graph, live: live} = socket.assigns

    case Enum.find(graph.nodes, &(&1.key == key)) do
      nil ->
        assign(socket, selected: nil, details: nil)

      %{key: "handles"} = node ->
        socket = if socket.assigns.handles, do: socket, else: assign(socket, :handles, handles())
        details = about(node, socket.assigns.handles)
        assign(socket, :details, Map.put(details, :links, links(graph, key)))

      node ->
        assign(socket, :details, Map.put(about(node, live), :links, links(graph, key)))
    end
  end

  defp handles do
    list = Handles.list()
    %{count: length(list), latest: list |> Enum.take(-3) |> Enum.map(& &1["handle"])}
  end

  # Who the node talked to in the window: per partner, messages each way
  # and the newest one.
  defp links(graph, key) do
    graph.edges
    |> Enum.filter(&(&1.from == key or &1.to == key))
    |> Enum.group_by(&if(&1.from == key, do: &1.to, else: &1.from))
    |> Enum.map(fn {other, edges} ->
      last = Enum.max_by(edges, & &1.seq)

      %{
        name: lane_name(graph, other),
        sent: edges |> Enum.filter(&(&1.from == key)) |> Enum.map(& &1.count) |> Enum.sum(),
        got: edges |> Enum.filter(&(&1.to == key)) |> Enum.map(& &1.count) |> Enum.sum(),
        last: last.label,
        seq: last.seq
      }
    end)
    |> Enum.sort_by(& &1.seq, :desc)
  end

  defp about(%{key: "w:" <> id} = node, live) do
    id = String.to_integer(id)
    w = live[id]
    # Bounded reads: spawn and the first serve come early, the rest is recent.
    head = EventLog.head_for_id(id, 20)
    events = EventLog.tail_for_id(id, 400)
    spawn = Enum.find(head ++ events, &(&1["type"] == "spawn"))
    serve = (head ++ events) |> Enum.filter(&(&1["type"] == "serve")) |> List.last()
    exit = events |> Enum.filter(&(&1["type"] == "exit")) |> List.last()
    agent = w && w.spec[:agent]
    status = (w && w.status) || node.status

    %{
      title: node.label,
      kind: kind_name(node),
      status: status,
      link: ~p"/workers/#{id}",
      purpose: agent && agent.purpose,
      describe: !agent && serve && present(serve["data"]["describe"]),
      doing: doing(w, status, events, exit),
      facts:
        [
          {"Language", agent && "Claude agent", spawn && spawn["data"]["lang"]},
          {"Model", agent && (agent.model || "default model"), nil},
          {"Pool", agent && agent.pool, nil},
          {"Uses", agent && join(agent[:services]), nil},
          {"Functions", !agent && serve && join(serve["data"]["fns"]), nil},
          {"Leases", w && join(w.spec[:leases]), nil},
          {"Network", w && join(w.spec[:network]), nil}
        ]
        |> Enum.map(fn {label, a, b} -> {label, a || b} end)
        |> Enum.reject(fn {_, v} -> v in [nil, ""] end),
      started: spawn && spawn["ts"]
    }
  end

  defp about(%{key: "model"}, live) do
    %{
      title: "Model",
      kind: "Claude Code",
      status: nil,
      link: ~p"/timeline",
      purpose: nil,
      describe:
        "The coding agent driving this project. It sends directives in ticks and reads the digest Universe answers with.",
      doing: nil,
      facts: [
        {"Live workers", live |> Enum.count(fn {_, w} -> live_status?(w) end) |> to_string()}
      ],
      started: nil
    }
  end

  defp about(%{key: "universe"}, live) do
    count = fn kind -> Enum.count(live, fn {_, w} -> w.kind == kind and live_status?(w) end) end

    %{
      title: "Universe",
      kind: "kernel",
      status: nil,
      link: ~p"/system",
      purpose: nil,
      describe:
        "Runs every worker in its sandbox, routes calls to services and agents, and answers each tick with a digest.",
      doing: nil,
      facts: [
        {"Runs", to_string(count.("run"))},
        {"Services and agents", to_string(count.("serve"))},
        {"Calls in flight", to_string(count.("call"))}
      ],
      started: nil
    }
  end

  defp about(%{key: "handles"}, handles) do
    %{
      title: "Handles",
      kind: "stored data",
      status: nil,
      link: ~p"/handles",
      purpose: nil,
      describe:
        "Values workers stored with U.put. Only previews reach the model; code reads them back with U.get.",
      doing: nil,
      facts: [
        {"Stored", to_string(handles.count)},
        {"Latest", join(handles.latest)}
      ],
      started: nil
    }
  end

  defp about(node, _live) do
    %{
      title: node.label,
      kind: node.sub,
      status: nil,
      link: ~p"/workers",
      purpose: nil,
      describe:
        "Older workers, folded so the column stays readable. The Workers page lists them all.",
      doing: nil,
      facts: [],
      started: nil
    }
  end

  # What a worker is doing now, or how it ended.
  defp doing(w, status, events, exit) do
    progress = events |> Enum.filter(&(&1["type"] == "progress")) |> List.last()
    out = events |> Enum.filter(&(&1["type"] in ["stdout", "stderr"])) |> List.last()

    cond do
      status == "asking" and w -> "Asking: #{w.question}"
      status in ~w(running serving queued) and progress -> progress["data"]["text"]
      status in ~w(running queued) and out -> last_line(out["data"]["text"])
      status == "serving" -> "Waiting for calls"
      exit -> exit_text(exit["data"])
      true -> nil
    end
  end

  defp exit_text(%{"status" => "done"} = d),
    do: if(d["result_text"], do: "Done: #{d["result_text"]}", else: "Done")

  defp exit_text(d), do: Enum.join(Enum.reject([d["status"], d["reason"]], &is_nil/1), ": ")

  defp last_line(text) when is_binary(text),
    do: text |> String.split("\n", trim: true) |> List.last()

  defp last_line(_), do: nil

  defp live_status?(w), do: w.status in ~w(queued running serving asking)

  defp kind_name(%{kind: :agent}), do: "agent"
  defp kind_name(%{kind: :service}), do: "service"
  defp kind_name(_), do: "run"

  defp join(list) when is_list(list) and list != [], do: Enum.join(list, ", ")
  defp join(_), do: nil

  defp present(s) when is_binary(s) and s != "", do: s
  defp present(_), do: nil

  defp recent?(%{"ts" => ts}, cutoff) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, at, _} -> DateTime.compare(at, cutoff) != :lt
      _ -> true
    end
  end

  defp recent?(_event, _cutoff), do: true

  defp now, do: System.monotonic_time(:millisecond)

  defp window_label(60), do: "1 min"
  defp window_label(300), do: "5 min"
  defp window_label(1800), do: "30 min"

  defp window_words(60), do: "minute"
  defp window_words(s), do: "#{div(s, 60)} minutes"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={:flow}>
      <.page_header title="Flow">
        <:meta><.live_dot /></:meta>
        <:subtitle>
          Who talked to whom in the last {window_words(@window_s)}. A line lights up while a message crosses it.
        </:subtitle>
        <:actions>
          <.seg
            id="flow-window"
            id_prefix="window-"
            options={for w <- [60, 300, 1800], do: {w, window_label(w)}}
            value={@window_s}
            event="window"
            key="s"
          />
        </:actions>
      </.page_header>

      <div
        class="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_21rem]"
        phx-window-keydown="deselect"
        phx-key="Escape"
      >
        <div id="flow-graph" class="py-4">
          <.topology graph={@graph} active={@active} selected={@selected} />
        </div>
        <.details details={@details} />
      </div>

      <section id="flow-recent" class="max-w-4xl space-y-3">
        <h2 class="text-sm font-semibold">Latest messages</h2>
        <p :if={@graph.recent == []} class="text-muted">
          Nothing in this window. Messages show up here as soon as the model sends a tick.
        </p>
        <ol :if={@graph.recent != []}>
          <li
            :for={r <- @graph.recent}
            class="grid grid-cols-[3.75rem_minmax(0,1fr)] gap-x-4 py-0.5 text-[13px] leading-6 sm:grid-cols-[4.25rem_minmax(0,15rem)_minmax(0,1fr)]"
          >
            <span class="tabular-nums text-muted">{r.at}</span>
            <span class="truncate">
              {lane_name(@graph, r.from)} <span class="text-muted">to</span> {lane_name(@graph, r.to)}
            </span>
            <span class="col-start-2 truncate text-muted sm:col-start-auto" title={r.label}>
              {r.label}
            </span>
          </li>
        </ol>
        <p class="pt-2 text-muted">
          To follow one tick step by step, open it from the <.link
            navigate={~p"/timeline"}
            class="text-base-content underline decoration-base-content/30 underline-offset-2 transition hover:decoration-base-content"
          >Timeline</.link>.
        </p>
      </section>
    </Layouts.app>
    """
  end

  attr :details, :map, default: nil

  defp details(%{details: nil} = assigns) do
    ~H"""
    <aside
      id="flow-details"
      class="rounded-xl border border-dashed border-base-300 px-4 py-6 text-center text-muted"
    >
      Click a node to see what it is, what it's doing and who it talks to.
    </aside>
    """
  end

  defp details(assigns) do
    ~H"""
    <aside
      id="flow-details"
      class="flow-panel space-y-4 rounded-xl border border-base-300 bg-base-200/40 p-4"
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 class="truncate text-base font-semibold">{@details.title}</h2>
          <p class="text-xs text-muted">{@details.kind}</p>
        </div>
        <div class="flex shrink-0 items-center gap-2">
          <.badge :if={@details.status} status={@details.status} />
          <button
            type="button"
            id="flow-details-close"
            phx-click="deselect"
            class="rounded-md p-1 text-muted transition hover:bg-base-300/60 hover:text-base-content"
            aria-label="Close details"
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </div>
      </div>

      <div :if={@details.doing} id="flow-details-doing" class="rounded-lg bg-base-100 px-3 py-2">
        <div class="text-xs text-muted">Now</div>
        <p class="mt-0.5 break-words">{@details.doing}</p>
      </div>

      <div :if={@details.purpose}>
        <div class="text-xs text-muted">Purpose</div>
        <p
          class="mt-0.5 line-clamp-6 whitespace-pre-line leading-relaxed"
          title={@details.purpose}
          phx-no-format
        >{String.trim(@details.purpose)}</p>
      </div>
      <p :if={@details.describe} class="text-muted">{@details.describe}</p>

      <dl
        :if={@details.facts != [] or @details.started}
        class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1.5"
      >
        <%= for {label, value} <- @details.facts do %>
          <dt class="text-muted">{label}</dt>
          <dd class="truncate" title={value}>{value}</dd>
        <% end %>
        <dt :if={@details.started} class="text-muted">Started</dt>
        <dd :if={@details.started}><.stamp ts={@details.started} /></dd>
      </dl>

      <div :if={@details.links != []} class="space-y-1.5">
        <h3 class="text-xs text-muted">Talks to</h3>
        <ul id="flow-details-links" class="space-y-1.5">
          <li :for={l <- @details.links} class="rounded-lg bg-base-100 px-3 py-1.5">
            <div class="flex items-baseline justify-between gap-2">
              <span class="truncate font-medium">{l.name}</span>
              <span class="shrink-0 text-xs tabular-nums text-muted">
                {l.sent} sent · {l.got} received
              </span>
            </div>
            <p class="truncate text-xs text-muted" title={l.last}>last: {l.last}</p>
          </li>
        </ul>
      </div>

      <.link
        navigate={@details.link}
        id="flow-details-open"
        class="inline-flex items-center gap-1 text-sm font-medium text-base-content underline decoration-base-content/30 underline-offset-2 transition hover:decoration-base-content"
      >
        Open full page
      </.link>
    </aside>
    """
  end

  defp lane_name(graph, key) do
    case Enum.find(graph.nodes, &(&1.key == key)) do
      nil -> key
      n -> n.label
    end
  end
end
