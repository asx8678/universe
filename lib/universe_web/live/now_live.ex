defmodule UniverseWeb.NowLive do
  @moduledoc """
  The home page: what is happening in this universe right now.

    * counters: live workers, running, services, agents idle/busy, asking,
      ticks
    * attention: workers waiting for the model's `reply`
    * agents and services: one card each; agents show model, pool,
      idle/busy/asking, the task in hand, the last answer and context size
    * running now: runs and calls in flight with a live clock and their last
      line
    * activity: every event as a readable line, newest first, filterable and
      pausable (a LiveView stream capped at #{150} rows)

  State comes from `Universe.Tick.snapshot/0` (refreshed, throttled, on new
  events) and the `"events"` PubSub topic. Read-only apart from Stop all.
  """

  use UniverseWeb, :live_view

  alias Universe.{Digest, EventLog, Tick}
  alias UniverseWeb.Activity

  @feed_max 150
  @refresh_ms 250
  @live ~w(queued running serving asking)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Universe.PubSub, EventLog.topic())
      :timer.send_interval(1000, :clock)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Now",
       filter: "all",
       paused: false,
       missed: 0,
       pending: false,
       fold: Activity.new_feed(),
       ticks: length(EventLog.by_types(["tick_in"]))
     )
     |> stream_configure(:feed, dom_id: & &1.key)
     |> load()
     |> reset_feed()}
  end

  ## Events

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    filter = if filter in Activity.filters(), do: filter, else: "all"
    {:noreply, socket |> assign(filter: filter) |> reset_feed()}
  end

  def handle_event("pause", _params, socket) do
    if socket.assigns.paused,
      do: {:noreply, socket |> assign(paused: false) |> reset_feed()},
      else: {:noreply, assign(socket, paused: true, missed: 0)}
  end

  def handle_event("stop_all", _params, socket) do
    {:ok, n} = Tick.stop_all()
    {:noreply, socket |> put_flash(:info, "Stopped #{n} live worker(s).") |> load()}
  end

  @impl true
  def handle_info({:event, e}, socket) do
    socket =
      socket
      |> feed(e)
      |> then(&if(e["type"] == "tick_in", do: update(&1, :ticks, fn n -> n + 1 end), else: &1))

    if socket.assigns.pending do
      {:noreply, socket}
    else
      Process.send_after(self(), :refresh, @refresh_ms)
      {:noreply, assign(socket, :pending, true)}
    end
  end

  def handle_info(:refresh, socket), do: {:noreply, socket |> assign(:pending, false) |> load()}

  # Only re-render the clocks when something is in flight.
  def handle_info(:clock, socket) do
    if socket.assigns.running != [] or socket.assigns.agents != [],
      do: {:noreply, assign(socket, :now, now())},
      else: {:noreply, socket}
  end

  defp feed(socket, e) do
    cond do
      not Activity.in_filter?(e, socket.assigns.filter) -> socket
      socket.assigns.paused -> update(socket, :missed, &(&1 + 1))
      true -> step(socket, e)
    end
  end

  # New rows go on top; a row that changed (progress, a fold that grew)
  # moves to the top with its new text instead of piling up.
  defp step(socket, e) do
    {fold, {action, row}} = Activity.feed_step(socket.assigns.fold, e)
    socket = assign(socket, :fold, fold)

    socket =
      if action == :update or row.type == "progress",
        do: stream_delete_by_dom_id(socket, :feed, row.key),
        else: socket

    stream_insert(socket, :feed, row, at: 0, limit: @feed_max)
  end

  defp reset_feed(socket) do
    since = max(EventLog.last_seq() - 2000, 0)

    {fold, rows} =
      EventLog.since(since)
      |> Enum.filter(&Activity.in_filter?(&1, socket.assigns.filter))
      |> Activity.fold()

    socket
    |> assign(missed: 0, fold: fold)
    |> stream(:feed, Enum.take(rows, @feed_max), reset: true)
  end

  ## State

  defp load(socket) do
    workers = Tick.snapshot() |> Map.values()
    live = Enum.filter(workers, &(&1.status in @live))
    services = live |> Enum.filter(&(&1.kind == "serve")) |> Enum.sort_by(& &1.id)

    running_calls =
      for w <- live, w.kind == "call", w.status == "running", into: %{}, do: {w.spec[:service], w}

    agents = for w <- services, agent?(w), do: agent_card(w, running_calls)
    code_services = for w <- services, not agent?(w), do: service_card(w)

    running =
      live
      |> Enum.filter(&(&1.status in ["running", "asking"] and &1.kind in ["run", "call"]))
      |> Enum.sort_by(& &1.id)

    asking = Enum.filter(live, &(&1.status == "asking"))

    assign(socket,
      now: now(),
      agents: agents,
      services: code_services,
      running: running,
      asking: asking,
      stats: %{
        live: length(live),
        running: Enum.count(live, &(&1.status == "running" and &1.kind != "serve")),
        services: length(code_services),
        agents: length(agents),
        idle: Enum.count(agents, &(&1.state == "idle")),
        busy: Enum.count(agents, &(&1.state in ["busy", "asking"])),
        asking: length(asking)
      }
    )
  end

  defp agent?(w), do: match?(%{agent: %{}}, w.spec)

  defp agent_card(w, running_calls) do
    call = running_calls[w.service]

    last =
      w.service &&
        List.first(Enum.reject(Activity.agent_tasks(w.service), &(&1.status == "running")))

    %{
      id: w.id,
      name: w.service || w.spec[:service],
      model: w.spec.agent.model || "default model",
      pool: w.spec.agent.pool,
      purpose: w.spec.agent.purpose,
      state:
        cond do
          w.status == "asking" -> "asking"
          w.status != "serving" -> "starting"
          call -> "busy"
          true -> "idle"
        end,
      question: w.question,
      task: call && prompt_of(call.spec),
      task_started: call && call.started_ms,
      progress: latest_progress(w.id),
      last: last
    }
  end

  defp service_card(w) do
    %{
      id: w.id,
      name: w.service || w.spec[:service],
      state: w.status,
      fns: w.fns,
      describe: w.describe,
      started: w.started_ms
    }
  end

  defp latest_progress(id) do
    case EventLog.for_id(id) |> Enum.filter(&(&1["type"] == "progress")) |> List.last() do
      nil -> nil
      e -> e["data"]["text"]
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  ## View

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={:now}>
      <.page_header title="Now">
        <:meta><.live_dot /></:meta>
        <:subtitle>
          <span id="stats" class="flex flex-wrap items-center gap-x-2 gap-y-1">
            <.stat id="stat-live" value={@stats.live} label="live" />
            <.stat
              :if={@stats.running > 0}
              id="stat-running"
              value={@stats.running}
              label="running"
              tone={:active}
            />
            <.stat
              :if={@stats.asking > 0}
              id="stat-asking"
              value={@stats.asking}
              label="waiting on the model"
              tone={:warn}
            />
            <.stat
              :if={@stats.agents > 0}
              id="stat-agents"
              value={@stats.agents}
              label={agents_label(@stats)}
              tone={@stats.busy > 0 && :busy}
            />
            <.stat
              :if={@stats.services > 0}
              id="stat-services"
              value={@stats.services}
              label={if @stats.services == 1, do: "service", else: "services"}
            />
            <.stat id="stat-ticks" value={@ticks} label={if @ticks == 1, do: "tick", else: "ticks"} />
          </span>
        </:subtitle>
        <:actions>
          <.action
            id="stop-all"
            variant={:danger}
            phx-click="stop_all"
            data-confirm="Kill every live worker, service, agent and call?"
          >
            <.icon name="hero-stop-circle-micro" class="size-4" /> Stop all
          </.action>
        </:actions>
      </.page_header>

      <section
        :if={@asking != []}
        id="attention"
        class="space-y-1 rounded-xl border border-warning/40 bg-warning/8 p-3"
      >
        <h2 class="flex items-center gap-2 px-2 text-sm font-semibold text-warning">
          <.icon name="hero-chat-bubble-left-ellipsis-micro" class="size-4" />
          Waiting for the model's reply
        </h2>
        <.link
          :for={w <- @asking}
          navigate={~p"/workers/#{w.id}"}
          class="flex gap-2 rounded-lg px-2 py-1.5 transition hover:bg-warning/10"
        >
          <span class="shrink-0 font-mono text-muted">#{w.id}</span>
          <span class="shrink-0 font-medium">{w.label}</span>
          <span class="min-w-0">{w.question}</span>
        </.link>
      </section>

      <div class="grid gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,30rem)]">
        <div class="min-w-0 space-y-8">
          <.panel id="agents" title="Agents" count={length(@agents)}>
            <.empty :if={@agents == []}>
              No agents. The model starts one with a <code class="font-mono text-xs">serve</code>
              that has an <code class="font-mono text-xs">agent</code>
              block.
            </.empty>
            <div :if={@agents != []} class="grid gap-3 xl:grid-cols-2">
              <.agent_card :for={a <- @agents} agent={a} now={@now} />
            </div>
          </.panel>

          <.panel :if={@services != []} id="services" title="Services" count={length(@services)}>
            <ul class="divide-y divide-base-300/70 overflow-hidden rounded-xl border border-base-300 bg-base-100">
              <li :for={s <- @services} id={"service-#{s.id}"}>
                <.link
                  navigate={~p"/workers/#{s.id}"}
                  class="flex items-start gap-3 px-4 py-3 transition hover:bg-base-200/60"
                >
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2">
                      <span class="font-medium">{s.name}</span>
                      <span class="font-mono text-xs text-muted">#{s.id}</span>
                    </div>
                    <p :if={s.describe not in [nil, ""]} class="mt-0.5 text-muted">{s.describe}</p>
                    <div :if={s.fns != []} class="mt-1.5 flex flex-wrap gap-1">
                      <code
                        :for={f <- s.fns}
                        class="rounded bg-base-200 px-1.5 py-px font-mono text-xs"
                      >{f}</code>
                    </div>
                  </div>
                  <.badge status={s.state} />
                </.link>
              </li>
            </ul>
          </.panel>

          <.panel id="running" title="Running now" count={length(@running)}>
            <.empty :if={@running == []}>Nothing in flight.</.empty>
            <ul
              :if={@running != []}
              class="divide-y divide-base-300/70 overflow-hidden rounded-xl border border-base-300 bg-base-100"
            >
              <li :for={w <- @running} id={"running-#{w.id}"}>
                <.link
                  navigate={~p"/workers/#{w.id}"}
                  class="flex items-center gap-3 px-4 py-2.5 transition hover:bg-base-200/60"
                >
                  <.badge status={w.status} />
                  <span class="shrink-0 font-mono text-xs text-muted">#{w.id}</span>
                  <span class="shrink-0 font-medium">{w.label}</span>
                  <span class="min-w-0 truncate text-muted">{running_detail(w)}</span>
                  <span class="ml-auto shrink-0 text-xs tabular-nums text-muted">
                    {Digest.duration(@now - (w.started_ms || @now))}
                  </span>
                </.link>
              </li>
            </ul>
          </.panel>
        </div>

        <.panel id="activity" title="Activity">
          <:actions>
            <.action
              id="feed-pause"
              variant={if @paused, do: :default, else: :ghost}
              phx-click="pause"
              class={@paused && "text-warning"}
            >
              <%= if @paused do %>
                <.icon name="hero-play-micro" class="size-3.5" />
                resume{if @missed > 0, do: " · #{@missed} new"}
              <% else %>
                <.icon name="hero-pause-micro" class="size-3.5" /> pause
              <% end %>
            </.action>
          </:actions>
          <.seg
            id="feed-filters"
            id_prefix="filter-"
            options={for f <- Activity.filters(), do: {f, f}}
            value={@filter}
            event="filter"
            key="filter"
          />
          <ol
            id="feed"
            phx-update="stream"
            class="max-h-[calc(100vh-14rem)] overflow-y-auto rounded-xl border border-base-300 bg-base-100"
          >
            <li id="feed-empty" class="hidden px-4 py-6 text-center text-muted only:block">
              Quiet. Events show up here as they happen.
            </li>
            <li
              :for={{dom_id, r} <- @streams.feed}
              id={dom_id}
              class="grid grid-cols-[4.25rem_4.75rem_minmax(0,1fr)] gap-x-2 border-b border-base-300/60 px-3 py-1.5 text-[13px] leading-5 last:border-0 motion-safe:animate-[fadein_0.25s_ease-out]"
            >
              <span
                class="text-xs leading-5 tabular-nums text-muted"
                title={UniverseWeb.Format.full(r.ts)}
              >{r.at}</span>
              <span
                class={["truncate text-xs font-medium leading-5", tone_text(r.tone)]}
                title={r.type}
              >{r.type}</span>
              <span class="min-w-0">
                <.link
                  :if={r.id}
                  navigate={~p"/workers/#{r.id}"}
                  class="mr-1 font-mono text-xs text-muted hover:text-base-content hover:underline"
                >#{r.id}</.link>
                <span :if={is_nil(r.id) and r.tick} class="mr-1 font-mono text-xs text-muted">t{r.tick}</span>
                <span
                  class={[
                    "break-words",
                    r.tone == :muted && "text-muted",
                    r.tone == :bad && "text-error"
                  ]}
                  title={r.text}
                >{r.text}</span>
                <span
                  :if={r.count > 1}
                  class="ml-1 rounded bg-base-200 px-1 py-px text-xs font-medium tabular-nums text-muted"
                >×{r.count}</span>
              </span>
            </li>
          </ol>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tone, :any, default: nil

  defp stat(assigns) do
    ~H"""
    <span
      id={@id}
      class="inline-flex items-baseline gap-1 after:ml-1 after:text-base-300 after:content-['·'] last:after:content-none"
    >
      <span class={["font-semibold tabular-nums text-base-content", @tone && tone_text(@tone)]}>{@value}</span>
      <span>{@label}</span>
    </span>
    """
  end

  defp agents_label(%{agents: n, idle: idle, busy: busy}) do
    word = if n == 1, do: "agent", else: "agents"
    "#{word} (#{busy} busy, #{idle} idle)"
  end

  attr :agent, :map, required: true
  attr :now, :integer, required: true

  defp agent_card(assigns) do
    ~H"""
    <.link
      id={"agent-#{@agent.id}"}
      navigate={~p"/workers/#{@agent.id}"}
      class={[
        "group flex flex-col rounded-xl border bg-base-100 p-4 transition hover:shadow-sm",
        @agent.state == "busy" && "border-accent/45",
        @agent.state == "asking" && "border-warning/55",
        @agent.state not in ["busy", "asking"] && "border-base-300 hover:border-base-content/25"
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="truncate font-medium">{@agent.name}</div>
          <div class="mt-0.5 truncate text-xs text-muted">
            {@agent.model}<span :if={@agent.pool}> · pool {@agent.pool}</span>
            · <span class="font-mono">#{@agent.id}</span>
          </div>
        </div>
        <.badge status={@agent.state} />
      </div>

      <p class="mt-2 line-clamp-2 text-muted" title={@agent.purpose}>{@agent.purpose}</p>

      <div
        :if={@agent.state == "busy" and @agent.task}
        class="mt-3 rounded-lg border border-accent/20 bg-accent/6 px-3 py-2"
      >
        <div class="flex items-center justify-between text-xs font-medium text-accent">
          <span>Working on</span>
          <span :if={@agent.task_started} class="tabular-nums">
            {Digest.duration(@now - @agent.task_started)}
          </span>
        </div>
        <div class="mt-0.5 line-clamp-2">{@agent.task}</div>
      </div>

      <div
        :if={@agent.state == "asking"}
        class="mt-3 rounded-lg border border-warning/25 bg-warning/8 px-3 py-2"
      >
        <div class="text-xs font-medium text-warning">Asks the model</div>
        <div class="mt-0.5">{@agent.question}</div>
      </div>

      <div :if={@agent.state == "idle" and @agent.last} class="mt-3">
        <div class="text-xs text-muted">Last answer</div>
        <div class="mt-0.5 line-clamp-2">
          {@agent.last.answer || (@agent.last.handle && "→ #{@agent.last.handle}") ||
            @agent.last.reason}
        </div>
      </div>

      <div
        :if={@agent.progress}
        class="mt-3 truncate border-t border-base-300/70 pt-2 font-mono text-xs text-muted"
      >
        {@agent.progress}
      </div>
    </.link>
    """
  end

  defp running_detail(%{status: "asking"} = w), do: "asks: #{w.question}"

  defp running_detail(%{kind: "call", spec: spec}) do
    case prompt_of(spec) do
      nil -> "#{spec[:service]}.#{spec[:fn]}"
      p -> "task → #{spec[:service]}: #{p}"
    end
  end

  defp running_detail(%{spec: spec}), do: Map.get(spec, :lang, "")

  defp prompt_of(%{args: %{"prompt" => p}}) when is_binary(p), do: p
  defp prompt_of(_), do: nil
end
