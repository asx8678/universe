defmodule UniverseWeb.SystemLive do
  @moduledoc """
  The daemon's live process tree with Universe's meaning attached: which
  process is a supervisor (and its strategy), which is a GenServer, what
  each one is for and who it talks to, and under every worker its OS
  processes. Refreshes every second while open; activity is reductions per
  second, a cheap measure of how busy a process is.
  """

  use UniverseWeb, :live_view

  alias UniverseWeb.SystemTree

  @poll_ms 1000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@poll_ms, :poll)

    {:ok,
     socket
     |> assign(page_title: "System", expanded: MapSet.new(), prev: %{}, prev_at: nil)
     |> load()}
  end

  @impl true
  def handle_event("toggle", %{"key" => key}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    {:noreply, socket |> assign(:expanded, expanded) |> load()}
  end

  @impl true
  def handle_info(:poll, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    snap = SystemTree.snapshot(socket.assigns.expanded)
    now = System.monotonic_time(:millisecond)

    current =
      for n <- SystemTree.flatten(snap.root), n.reductions, into: %{}, do: {n.key, n.reductions}

    rates =
      case socket.assigns.prev_at do
        nil ->
          %{}

        then ->
          secs = max(now - then, 1) / 1000

          Map.new(current, fn {key, r} ->
            {key, max(r - Map.get(socket.assigns.prev, key, r), 0) / secs}
          end)
      end

    assign(socket,
      root: snap.root,
      totals: snap.totals,
      rates: rates,
      prev: current,
      prev_at: now
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={:system}>
      <.page_header title="System">
        <:meta><.live_dot label="every second" /></:meta>
        <:subtitle>
          <span id="system-totals" class="flex flex-wrap gap-x-2 gap-y-1">
            <.total value={@totals.processes} label="Universe processes" />
            <.total value={@totals.workers} label="workers" />
            <.total value={@totals.os} label="OS processes" />
            <.total value={@totals[:beam_processes]} label="BEAM processes in all" />
            <.total value={mb(@totals[:beam_memory])} label="BEAM memory" />
          </span>
        </:subtitle>
        <:actions>
          <.action href="/dashboard/processes" variant={:ghost}>
            Raw process list <.icon name="hero-arrow-up-right-micro" class="size-3.5" />
          </.action>
        </:actions>
      </.page_header>

      <div id="system-legend" class="flex flex-wrap items-center gap-x-2 gap-y-1.5 text-xs text-muted">
        <.kind_badge kind={:supervisor} strategy={nil} /> restarts its children by strategy
        <.kind_badge kind={:dynamic_supervisor} strategy={nil} /> children started on demand
        <.kind_badge kind={:genserver} strategy={nil} /> a server process
        <.kind_badge kind={:task} strategy={nil} /> a short job
        <span class="inline-flex items-center gap-1 rounded-md bg-base-200 px-1.5 py-px font-mono text-base-content">
          <.icon name="hero-command-line" class="size-3" /> OS
        </span>
        an OS process · q = messages waiting · activity = reductions per second
      </div>

      <div :if={@root} id="system-tree" class="rounded-xl border border-base-300 bg-base-100 p-2">
        <ul class="text-sm">
          <.tree_node node={@root} rates={@rates} expanded={@expanded} />
        </ul>
      </div>
      <.empty :if={is_nil(@root)}>Universe.Supervisor is not running.</.empty>
    </Layouts.app>
    """
  end

  attr :node, :map, required: true
  attr :rates, :map, required: true
  attr :expanded, :any, required: true

  defp tree_node(assigns) do
    ~H"""
    <li id={"node-" <> dom_key(@node.key)} class="relative">
      <div class="group flex flex-wrap items-start gap-x-3 gap-y-0.5 rounded-lg px-2 py-1.5 transition hover:bg-base-200/70">
        <div class="flex min-w-0 flex-1 flex-wrap items-center gap-2">
          <.kind_badge kind={@node.kind} strategy={@node.strategy} />
          <span class="font-mono text-[13px] font-semibold">{@node.name}</span>
          <.badge :if={@node.status} status={@node.status} />
          <span :if={@node.detail} class="text-xs text-muted">{@node.detail}</span>
          <button
            :if={@node.expandable}
            id={"toggle-" <> dom_key(@node.key)}
            phx-click="toggle"
            phx-value-key={@node.key}
            class="rounded-md px-1.5 py-px text-xs text-muted ring-1 ring-inset ring-base-300 transition hover:bg-base-200 hover:text-base-content"
          >
            <%= if MapSet.member?(@expanded, @node.key) do %>
              hide children
            <% else %>
              + {@node.hidden} children
            <% end %>
          </button>
        </div>
        <div class="flex shrink-0 items-center gap-3 text-xs tabular-nums text-muted">
          <span
            :if={@node.queue}
            class={[@node.queue > 0 && "font-semibold text-warning"]}
            title="messages waiting"
          >
            q {@node.queue}
          </span>
          <span :if={@node.memory} title="process memory">{kb(@node.memory)}</span>
          <span :if={@node.reductions} class="flex items-center gap-1" title="reductions per second">
            <span class="h-1.5 w-16 overflow-hidden rounded-full bg-base-300">
              <span
                class="block h-full rounded-full bg-info transition-all"
                style={"width: #{activity(@rates[@node.key])}%"}
              ></span>
            </span>
            <span class="w-14 text-right">{rate(@rates[@node.key])}</span>
          </span>
        </div>
        <div :if={@node.role} class="basis-full pl-1 text-xs">
          <span>{@node.role}</span>
          <span :if={@node.talks} class="text-muted"> · {@node.talks}</span>
        </div>
      </div>

      <ul :if={@node.os != []} class="ml-5 border-l border-dashed border-base-content/20 pl-3">
        <.os_node :for={o <- @node.os} proc={o} />
      </ul>

      <ul :if={@node.children != []} class="ml-5 border-l border-base-content/15 pl-3">
        <.tree_node :for={c <- @node.children} node={c} rates={@rates} expanded={@expanded} />
      </ul>
      <p :if={@node.children != [] and @node.hidden > 0} class="ml-8 text-xs text-muted">
        … and {@node.hidden} more
      </p>
    </li>
    """
  end

  attr :proc, :map, required: true

  defp os_node(assigns) do
    ~H"""
    <li id={"os-#{@proc.pid}"}>
      <div class="flex items-center gap-2 rounded-lg px-2 py-1 font-mono text-xs transition hover:bg-base-200/70">
        <.icon name="hero-command-line" class="size-3.5 shrink-0 text-muted" />
        <span class="shrink-0 text-muted">pid {@proc.pid}</span>
        <span class="shrink-0 text-muted">{kb(@proc.rss_kb * 1024)}</span>
        <span class="min-w-0 truncate" title={@proc.command}>{@proc.command}</span>
      </div>
      <ul :if={@proc.children != []} class="ml-4 border-l border-dashed border-base-content/20 pl-3">
        <.os_node :for={c <- @proc.children} proc={c} />
      </ul>
    </li>
    """
  end

  attr :kind, :atom, required: true
  attr :strategy, :atom, default: nil

  defp kind_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex shrink-0 items-center rounded-md px-1.5 py-px text-xs font-medium",
      kind_class(@kind)
    ]}>
      {kind_label(@kind)}<span :if={@strategy} class="font-normal">&nbsp;· {@strategy}</span>
    </span>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp total(assigns) do
    ~H"""
    <span class="inline-flex items-baseline gap-1 after:ml-1 after:text-base-300 after:content-['·'] last:after:content-none">
      <span class="font-semibold tabular-nums text-base-content">{@value}</span>
      <span>{@label}</span>
    </span>
    """
  end

  defp kind_label(:supervisor), do: "supervisor"
  defp kind_label(:dynamic_supervisor), do: "dynamic supervisor"
  defp kind_label(:task_supervisor), do: "task supervisor"
  defp kind_label(:genserver), do: "GenServer"
  defp kind_label(:task), do: "task"
  defp kind_label(:registry), do: "registry"
  defp kind_label(:down), do: "down"
  defp kind_label(_), do: "process"

  defp kind_class(k) when k in [:supervisor, :dynamic_supervisor, :task_supervisor],
    do: "bg-accent/15 text-accent"

  defp kind_class(:genserver), do: "bg-info/15 text-info"
  defp kind_class(:task), do: "bg-success/15 text-success"
  defp kind_class(:down), do: "bg-error/15 text-error"
  defp kind_class(_), do: "bg-base-200 text-muted"

  defp dom_key(key), do: key |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.trim("-")

  defp kb(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp kb(bytes), do: "#{div(bytes, 1024)} KB"

  defp mb(nil), do: "–"
  defp mb(bytes), do: "#{round(bytes / 1_048_576)} MB"

  defp rate(nil), do: "–"
  defp rate(r) when r >= 1_000_000, do: "#{Float.round(r / 1_000_000, 1)}M/s"
  defp rate(r) when r >= 1000, do: "#{round(r / 1000)}k/s"
  defp rate(r), do: "#{round(r)}/s"

  # Log scale: 10/s is a sliver, 10M/s is full.
  defp activity(nil), do: 0
  defp activity(r) when r <= 1, do: 0
  defp activity(r), do: min(100, round(:math.log10(r) / 7 * 100))
end
