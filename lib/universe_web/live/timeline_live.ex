defmodule UniverseWeb.TimelineLive do
  @moduledoc """
  The conversation between the model and Universe, exactly as the model saw
  it: per tick, the directives sent and the digest returned, with token
  estimates (chars / 4), wait time and the wake rule that fired.

  Built from `tick_in`/`tick_out` events and kept live through the `"events"`
  PubSub topic; ticks live in a LiveView stream, not in assigns. The one write
  action anywhere in the observer is Stop all.
  """

  use UniverseWeb, :live_view

  import UniverseWeb.TickComponents

  alias Universe.EventLog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Universe.PubSub, EventLog.topic())
    ticks = ticks_from_events(EventLog.by_types(["tick_in", "tick_out"]))

    {:ok,
     socket
     |> assign(:page_title, "Timeline")
     |> assign(:count, length(ticks))
     |> stream(:ticks, ticks)}
  end

  @impl true
  def handle_event("stop_all", _params, socket) do
    {:ok, n} = Universe.Tick.stop_all()
    {:noreply, put_flash(socket, :info, "Stopped #{n} live worker(s).")}
  end

  @impl true
  def handle_info({:event, %{"type" => "tick_in"} = e}, socket) do
    {:noreply,
     socket
     |> update(:count, &(&1 + 1))
     |> stream_insert(:ticks, build_tick(e["tick"], [e]), at: 0)}
  end

  def handle_info({:event, %{"type" => "tick_out"} = e}, socket) do
    tick_in = Enum.find(EventLog.for_tick(e["tick"]), &(&1["type"] == "tick_in"))
    {:noreply, stream_insert(socket, :ticks, build_tick(e["tick"], [tick_in, e]))}
  end

  def handle_info({:event, _}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={:timeline}>
      <.page_header title="Tick timeline">
        <:meta>
          <span class="text-sm tabular-nums text-muted">{@count}</span>
        </:meta>
        <:subtitle>
          Each tick as the model saw it: what it sent and the digest it got back, newest first.
        </:subtitle>
        <:actions>
          <.action
            id="stop-all"
            variant={:danger}
            phx-click="stop_all"
            data-confirm="Kill every live worker, service and call?"
          >
            <.icon name="hero-stop-circle-micro" class="size-4" /> Stop all
          </.action>
        </:actions>
      </.page_header>

      <.empty :if={@count == 0}>No ticks yet. They appear here as the model sends them.</.empty>

      <div id="ticks" phx-update="stream" class="space-y-4">
        <.tick_card :for={{dom_id, t} <- @streams.ticks} id={dom_id} tick={t} flow_link />
      </div>
    </Layouts.app>
    """
  end
end
