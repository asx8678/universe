defmodule UniverseWeb.TickFlowLive do
  @moduledoc """
  The flow of one tick as a sequence diagram: what the model asked for and
  everything that happened until its next tick, as messages between the
  model, Universe, workers, services, agents and the handle store.

  While the tick is still the latest one its window is open, so the page
  follows new events (throttled).
  """

  use UniverseWeb, :live_view

  import UniverseWeb.FlowComponents

  alias Universe.EventLog
  alias UniverseWeb.Flow

  @refresh_ms 300

  @impl true
  def mount(%{"tick" => tick}, _session, socket) do
    case Integer.parse(tick) do
      {n, ""} ->
        if connected?(socket), do: Phoenix.PubSub.subscribe(Universe.PubSub, EventLog.topic())
        {:ok, socket |> assign(tick: n, page_title: "Flow t#{n}", pending: false) |> load()}

      _ ->
        {:ok, socket |> put_flash(:error, "No such tick") |> push_navigate(to: ~p"/timeline")}
    end
  end

  @impl true
  def handle_params(%{"tick" => tick}, _uri, socket) do
    case Integer.parse(tick) do
      {n, ""} when n != socket.assigns.tick ->
        {:noreply, socket |> assign(tick: n, page_title: "Flow t#{n}") |> load()}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:event, _}, %{assigns: %{open: false}} = socket), do: {:noreply, socket}
  def handle_info({:event, _}, %{assigns: %{pending: true}} = socket), do: {:noreply, socket}

  def handle_info({:event, _}, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, :pending, true)}
  end

  def handle_info(:refresh, socket), do: {:noreply, socket |> assign(:pending, false) |> load()}

  defp load(socket) do
    case Flow.window(socket.assigns.tick) do
      nil ->
        assign(socket, diagram: nil, open: false, prev: nil, next: nil)

      w ->
        assign(socket, diagram: Flow.diagram(w.events), open: w.open, prev: w.prev, next: w.next)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={:timeline}>
      <.page_header title={"Flow of tick t#{@tick}"} back={~p"/timeline"} back_label="Timeline">
        <:meta><.live_dot :if={@open} id="flow-live" /></:meta>
        <:subtitle>
          Everything from this tick until the model's next one, as messages between lanes.
          Hover a label for its full text.
        </:subtitle>
        <:actions>
          <.action :if={@prev} id="flow-prev" patch={~p"/timeline/#{@prev}"}>
            <.icon name="hero-arrow-left-micro" class="size-3.5" /> t{@prev}
          </.action>
          <.action :if={@next} id="flow-next" patch={~p"/timeline/#{@next}"}>
            t{@next} <.icon name="hero-arrow-right-micro" class="size-3.5" />
          </.action>
        </:actions>
      </.page_header>

      <.empty :if={is_nil(@diagram)}>No tick t{@tick} in this log.</.empty>

      <div :if={@diagram} class="space-y-3">
        <div class="flex flex-wrap items-center gap-x-5 gap-y-2 text-xs text-muted" id="flow-legend">
          <span>{@diagram.events} events · {length(@diagram.rows)} rows · {length(@diagram.lanes)} lanes</span>
          <span class="flex items-center gap-1.5">
            <svg width="28" height="8"><line
              x1="0"
              y1="4"
              x2="28"
              y2="4"
              class="stroke-info"
              stroke-width="1.5"
            /></svg>
            request
          </span>
          <span class="flex items-center gap-1.5">
            <svg width="28" height="8">
              <line
                x1="0"
                y1="4"
                x2="28"
                y2="4"
                class="stroke-success"
                stroke-width="1.5"
                stroke-dasharray="5 4"
              />
            </svg>
            answer / return
          </span>
          <span class="flex items-center gap-1.5">
            <span class="inline-block h-3 w-6 rounded bg-base-200 ring-1 ring-base-content/15"></span>
            output / progress (folded)
          </span>
          <span class="flex items-center gap-2">
            <span class="size-2.5 rounded-sm bg-primary/60"></span>model <span class="size-2.5 rounded-sm bg-info/60"></span>run <span class="size-2.5 rounded-sm bg-success/60"></span>service <span class="size-2.5 rounded-sm bg-accent/60"></span>agent <span class="size-2.5 rounded-sm bg-warning/60"></span>handles
          </span>
        </div>
        <.sequence_diagram diagram={@diagram} />
      </div>
    </Layouts.app>
    """
  end
end
