defmodule UniverseWeb.FlowLive do
  @moduledoc """
  Who talks to whom, live: the model, Universe, runs, services, agents and
  the handle store as a graph (`UniverseWeb.Topology`). Each edge counts the
  messages that crossed it in the recent window; edges with new traffic
  animate for two seconds, with their last message shown. Below, the latest
  messages as text.
  """

  use UniverseWeb, :live_view

  import UniverseWeb.FlowComponents

  alias Universe.{EventLog, Tick}
  alias UniverseWeb.Topology

  # The graph covers the last window_s seconds (at most @max_events events).
  @max_events 2000
  @windows [60, 300, 1800]
  @refresh_ms 200
  @pulse_ms 2000

  @impl true
  def mount(_params, _session, socket) do
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
       window_s: 300
     )
     |> load(false)}
  end

  @impl true
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

    assign(socket,
      graph: graph,
      pulses: pulses,
      active: MapSet.new(Map.keys(pulses)),
      seen: last,
      window: length(events)
    )
  end

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-wrap items-baseline justify-between gap-3">
        <div class="flex items-center gap-3">
          <h1 class="text-xl font-semibold tracking-tight">Flow</h1>
          <span class="inline-flex items-center gap-1.5 rounded-full bg-success/10 px-2.5 py-0.5 text-xs font-medium text-success">
            <span class="size-1.5 animate-pulse rounded-full bg-success"></span> live
          </span>
        </div>
        <div class="flex items-center gap-3">
          <p class="text-sm opacity-60">
            Who talks to whom · {@window} events. Numbers count messages; moving edges just carried one.
          </p>
          <div class="flex gap-1" id="flow-window">
            <button
              :for={w <- [60, 300, 1800]}
              id={"window-#{w}"}
              phx-click="window"
              phx-value-s={w}
              class={[
                "rounded-full px-3 py-1 text-xs font-medium transition",
                @window_s == w && "bg-base-content text-base-100",
                @window_s != w && "bg-base-200 hover:bg-base-300"
              ]}
            >
              {window_label(w)}
            </button>
          </div>
        </div>
      </div>

      <div class="rounded-xl border border-base-300 bg-base-100 p-2" id="flow-graph">
        <.topology graph={@graph} active={@active} />
      </div>

      <div class="grid gap-4 lg:grid-cols-3">
        <section class="space-y-2 lg:col-span-2" id="flow-recent">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-80">Latest messages</h2>
          <ol class="divide-y divide-base-300/60 overflow-hidden rounded-xl border border-base-300 bg-base-100 text-xs">
            <li :if={@graph.recent == []} class="p-4 text-center opacity-60">Nothing yet.</li>
            <li :for={r <- @graph.recent} class="flex gap-2 px-3 py-1.5 font-mono">
              <span class="shrink-0 opacity-40">{r.at}</span>
              <span class="shrink-0 opacity-80">{lane_name(@graph, r.from)} → {lane_name(@graph, r.to)}</span>
              <span class="min-w-0 truncate opacity-70" title={r.label}>{r.label}</span>
            </li>
          </ol>
        </section>
        <section class="space-y-2 text-xs" id="flow-legend">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-80">Reading it</h2>
          <ul class="space-y-1.5 opacity-80">
            <li>
              <span class="font-semibold text-primary">Model ⇄ Universe</span>: ticks and digests
            </li>
            <li>
              <span class="font-semibold">Universe → worker</span>: start, tasks and calls; back: serving, answers, exits
            </li>
            <li>
              <span class="font-semibold text-info">run → service</span>: a <code>U.call</code>
              from code
            </li>
            <li>
              <span class="font-semibold text-warning">→ Handles</span>: stored data; Handles → worker: a read
            </li>
            <li>
              <span class="font-semibold text-warning">worker → Model</span>: a question; Model → worker: the reply
            </li>
            <li>Upper curve: request · lower curve: answer · faded node: worker gone</li>
          </ul>
          <p class="opacity-60">
            For one tick in order, open a tick's flow from the <.link
              navigate={~p"/timeline"}
              class="underline"
            >Timeline</.link>.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp lane_name(graph, key) do
    case Enum.find(graph.nodes, &(&1.key == key)) do
      nil -> key
      n -> n.label
    end
  end
end
