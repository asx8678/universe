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
      true -> insert_row(socket, row(e))
    end
  end

  # A progress row moves to the top with its new text instead of piling up.
  defp insert_row(socket, %{type: "progress"} = r) do
    socket
    |> stream_delete_by_dom_id(:feed, r.key)
    |> stream_insert(:feed, r, at: 0, limit: @feed_max)
  end

  defp insert_row(socket, r), do: stream_insert(socket, :feed, r, at: 0, limit: @feed_max)

  defp reset_feed(socket) do
    since = max(EventLog.last_seq() - 2000, 0)

    rows =
      EventLog.since(since)
      |> Enum.filter(&Activity.in_filter?(&1, socket.assigns.filter))
      |> Enum.take(-@feed_max)
      |> Enum.reverse()
      |> Enum.map(&row/1)
      |> Enum.uniq_by(& &1.key)

    socket |> assign(missed: 0) |> stream(:feed, rows, reset: true)
  end

  defp row(e), do: Activity.describe(e)

  ## State

  defp load(socket) do
    workers = Tick.snapshot() |> Map.values()
    live = Enum.filter(workers, &(&1.status in @live))
    services = live |> Enum.filter(&(&1.kind == "serve")) |> Enum.sort_by(& &1.id)

    running_calls =
      for w <- live, w.kind == "call", w.status == "running", into: %{}, do: {w.spec.service, w}

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
      name: w.service || w.spec.service,
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
      name: w.service || w.spec.service,
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
    <Layouts.app flash={@flash}>
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex items-center gap-3">
          <h1 class="text-xl font-semibold tracking-tight">Now</h1>
          <span class="inline-flex items-center gap-1.5 rounded-full bg-success/10 px-2.5 py-0.5 text-xs font-medium text-success">
            <span class="relative flex size-2">
              <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-success opacity-60"></span>
              <span class="relative inline-flex size-2 rounded-full bg-success"></span>
            </span>
            live
          </span>
        </div>
        <button
          id="stop-all"
          phx-click="stop_all"
          data-confirm="Kill every live worker, service, agent and call?"
          class="rounded-lg border border-error/40 px-3 py-1.5 text-sm font-medium text-error transition hover:bg-error hover:text-error-content active:scale-95"
        >
          Stop all
        </button>
      </div>

      <section id="stats" class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
        <.stat id="stat-live" label="Live" value={@stats.live} />
        <.stat
          id="stat-running"
          label="Running"
          value={@stats.running}
          tone={@stats.running > 0 && "info"}
        />
        <.stat id="stat-services" label="Services" value={@stats.services} />
        <.stat
          id="stat-agents"
          label="Agents idle / busy"
          value={"#{@stats.idle} / #{@stats.busy}"}
          tone={@stats.busy > 0 && "accent"}
        />
        <.stat
          id="stat-asking"
          label="Waiting on model"
          value={@stats.asking}
          tone={@stats.asking > 0 && "warning"}
        />
        <.stat id="stat-ticks" label="Ticks" value={@ticks} />
      </section>

      <section
        :if={@asking != []}
        id="attention"
        class="rounded-xl border border-warning/40 bg-warning/10 p-4 space-y-2"
      >
        <h2 class="flex items-center gap-2 text-sm font-semibold text-warning">
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-4" /> Waiting for the model's reply
        </h2>
        <.link
          :for={w <- @asking}
          navigate={~p"/workers/#{w.id}"}
          class="block rounded-lg px-2 py-1 text-sm transition hover:bg-warning/10"
        >
          <span class="font-mono font-semibold">#{w.id} {w.label}</span>
          <span class="opacity-80">asks: {w.question}</span>
        </.link>
      </section>

      <div class="grid gap-6 lg:grid-cols-5">
        <div class="space-y-6 lg:col-span-3 min-w-0">
          <section id="agents" class="space-y-3">
            <.section_title icon="hero-cpu-chip" title="Agents" count={length(@agents)} />
            <p
              :if={@agents == []}
              class="rounded-xl border border-dashed border-base-300 p-6 text-center text-sm opacity-60"
            >
              No agents. The model starts one with a <code class="font-mono">serve</code>
              that has an <code class="font-mono">agent</code>
              block.
            </p>
            <div class="grid gap-3 sm:grid-cols-2">
              <.agent_card :for={a <- @agents} agent={a} now={@now} />
            </div>
          </section>

          <section :if={@services != []} id="services" class="space-y-3">
            <.section_title icon="hero-server-stack" title="Services" count={length(@services)} />
            <div class="grid gap-3 sm:grid-cols-2">
              <.link
                :for={s <- @services}
                id={"service-#{s.id}"}
                navigate={~p"/workers/#{s.id}"}
                class="group rounded-xl border border-base-300 bg-base-100 p-4 transition hover:-translate-y-0.5 hover:border-base-content/20 hover:shadow-md"
              >
                <div class="flex items-center justify-between gap-2">
                  <span class="font-mono font-semibold">{s.name}</span>
                  <.pill state={s.state} />
                </div>
                <p :if={s.describe not in [nil, ""]} class="mt-1 text-sm opacity-70">{s.describe}</p>
                <p :if={s.fns != []} class="mt-2 font-mono text-xs opacity-60">
                  fns: {Enum.join(s.fns, ", ")}
                </p>
              </.link>
            </div>
          </section>

          <section id="running" class="space-y-3">
            <.section_title icon="hero-bolt" title="Running now" count={length(@running)} />
            <p
              :if={@running == []}
              class="rounded-xl border border-dashed border-base-300 p-6 text-center text-sm opacity-60"
            >
              Nothing in flight.
            </p>
            <ul class="divide-y divide-base-300 overflow-hidden rounded-xl border border-base-300 bg-base-100">
              <li :for={w <- @running} id={"running-#{w.id}"}>
                <.link
                  navigate={~p"/workers/#{w.id}"}
                  class="flex items-center gap-3 px-4 py-2.5 text-sm transition hover:bg-base-200"
                >
                  <span class="relative flex size-2 shrink-0">
                    <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-info opacity-50"></span>
                    <span class="relative inline-flex size-2 rounded-full bg-info"></span>
                  </span>
                  <span class="font-mono font-semibold">#{w.id}</span>
                  <span class="font-mono truncate">{w.label}</span>
                  <span class="truncate text-xs opacity-60">{running_detail(w)}</span>
                  <span class="ml-auto shrink-0 font-mono text-xs tabular-nums opacity-70">
                    {Digest.duration(@now - (w.started_ms || @now))}
                  </span>
                </.link>
              </li>
            </ul>
          </section>
        </div>

        <section id="activity" class="space-y-3 lg:col-span-2 min-w-0">
          <div class="flex items-center justify-between gap-2">
            <.section_title icon="hero-signal" title="Activity" />
            <button
              id="feed-pause"
              phx-click="pause"
              class={[
                "rounded-lg px-2.5 py-1 text-xs font-medium transition active:scale-95",
                @paused && "bg-warning/15 text-warning",
                !@paused && "bg-base-200 hover:bg-base-300"
              ]}
            >
              <%= if @paused do %>
                resume{if @missed > 0, do: " (#{@missed} new)"}
              <% else %>
                pause
              <% end %>
            </button>
          </div>
          <div class="flex flex-wrap gap-1.5" id="feed-filters">
            <button
              :for={f <- Activity.filters()}
              id={"filter-#{f}"}
              phx-click="filter"
              phx-value-filter={f}
              class={[
                "rounded-full px-3 py-1 text-xs font-medium transition",
                @filter == f && "bg-base-content text-base-100",
                @filter != f && "bg-base-200 hover:bg-base-300"
              ]}
            >
              {f}
            </button>
          </div>
          <ol
            id="feed"
            phx-update="stream"
            class="max-h-[75vh] overflow-y-auto rounded-xl border border-base-300 bg-base-100 font-mono text-xs"
          >
            <li id="feed-empty" class="hidden only:block p-6 text-center font-sans text-sm opacity-60">
              Quiet. Events show up here as they happen.
            </li>
            <li
              :for={{dom_id, r} <- @streams.feed}
              id={dom_id}
              class="flex gap-2 border-b border-base-300/60 px-3 py-1.5 last:border-0 animate-[fadein_0.4s_ease-out]"
            >
              <span class="shrink-0 tabular-nums opacity-40">{r.at}</span>
              <span class={["shrink-0 w-[4.5rem] truncate", tone_class(r.tone)]} title={r.type}>{r.type}</span>
              <.link
                :if={r.id}
                navigate={~p"/workers/#{r.id}"}
                class="shrink-0 opacity-70 hover:underline"
              >
                #{r.id}
              </.link>
              <span :if={is_nil(r.id) and r.tick} class="shrink-0 opacity-50">t{r.tick}</span>
              <span
                class={["min-w-0 break-words line-clamp-3", r.tone == :muted && "opacity-60"]}
                title={r.text}
              >
                {r.text}
              </span>
            </li>
          </ol>
        </section>
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
    <div id={@id} class="rounded-xl border border-base-300 bg-base-100 px-4 py-3 transition">
      <div class="text-xs font-medium uppercase tracking-wide opacity-60">{@label}</div>
      <div class={[
        "mt-1 text-2xl font-semibold tabular-nums",
        @tone == "info" && "text-info",
        @tone == "accent" && "text-accent",
        @tone == "warning" && "text-warning"
      ]}>
        {@value}
      </div>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, default: nil

  defp section_title(assigns) do
    ~H"""
    <h2 class="flex items-center gap-2 text-sm font-semibold uppercase tracking-wide opacity-80">
      <.icon name={@icon} class="size-4" />
      {@title}
      <span :if={@count} class="rounded-full bg-base-200 px-2 py-0.5 text-xs font-medium normal-case">{@count}</span>
    </h2>
    """
  end

  attr :agent, :map, required: true
  attr :now, :integer, required: true

  defp agent_card(assigns) do
    ~H"""
    <.link
      id={"agent-#{@agent.id}"}
      navigate={~p"/workers/#{@agent.id}"}
      class={[
        "group block rounded-xl border bg-base-100 p-4 transition hover:-translate-y-0.5 hover:shadow-md",
        @agent.state == "busy" && "border-accent/50 shadow-sm shadow-accent/10",
        @agent.state == "asking" && "border-warning/60",
        @agent.state not in ["busy", "asking"] && "border-base-300 hover:border-base-content/20"
      ]}
    >
      <div class="flex items-start justify-between gap-2">
        <div class="min-w-0">
          <div class="font-mono font-semibold truncate">{@agent.name}</div>
          <div class="mt-0.5 flex flex-wrap gap-1.5 text-xs opacity-60">
            <span>{@agent.model}</span>
            <span :if={@agent.pool}>· pool {@agent.pool}</span>
            <span>· #{@agent.id}</span>
          </div>
        </div>
        <.pill state={@agent.state} />
      </div>

      <p class="mt-2 line-clamp-2 text-sm opacity-70" title={@agent.purpose}>{@agent.purpose}</p>

      <div
        :if={@agent.state == "busy" and @agent.task}
        class="mt-3 rounded-lg bg-accent/10 px-3 py-2 text-sm"
      >
        <div class="flex items-center justify-between text-xs font-medium text-accent">
          <span>working on</span>
          <span :if={@agent.task_started} class="font-mono tabular-nums">
            {Digest.duration(@now - @agent.task_started)}
          </span>
        </div>
        <div class="mt-0.5 line-clamp-2">{@agent.task}</div>
      </div>

      <div :if={@agent.state == "asking"} class="mt-3 rounded-lg bg-warning/10 px-3 py-2 text-sm">
        <div class="text-xs font-medium text-warning">asks the model</div>
        <div class="mt-0.5">{@agent.question}</div>
      </div>

      <div :if={@agent.state == "idle" and @agent.last} class="mt-3 text-sm">
        <div class="text-xs font-medium opacity-60">last answer</div>
        <div class="mt-0.5 line-clamp-2 opacity-90">
          {@agent.last.answer || (@agent.last.handle && "→ #{@agent.last.handle}") ||
            @agent.last.reason}
        </div>
      </div>

      <div
        :if={@agent.progress}
        class="mt-3 truncate border-t border-base-300 pt-2 font-mono text-xs opacity-50"
      >
        {@agent.progress}
      </div>
    </.link>
    """
  end

  attr :state, :string, required: true

  defp pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex shrink-0 items-center gap-1.5 rounded-full px-2 py-0.5 text-xs font-medium",
      pill_class(@state)
    ]}>
      <span
        :if={@state in ["busy", "running", "starting"]}
        class="size-1.5 animate-pulse rounded-full bg-current"
      ></span>
      {@state}
    </span>
    """
  end

  defp pill_class("idle"), do: "bg-success/15 text-success"
  defp pill_class("serving"), do: "bg-success/15 text-success"
  defp pill_class("busy"), do: "bg-accent/15 text-accent"
  defp pill_class("asking"), do: "bg-warning/20 text-warning"
  defp pill_class(s) when s in ["running", "starting", "queued"], do: "bg-info/15 text-info"
  defp pill_class(_), do: "bg-base-200"

  defp tone_class(:model), do: "text-primary"
  defp tone_class(:good), do: "text-success"
  defp tone_class(:bad), do: "text-error"
  defp tone_class(:warn), do: "text-warning"
  defp tone_class(:info), do: "text-info"
  defp tone_class(_), do: "opacity-50"

  defp running_detail(%{status: "asking"} = w), do: "asks: #{w.question}"

  defp running_detail(%{kind: "call", spec: spec}) do
    case prompt_of(spec) do
      nil -> "#{spec.service}.#{spec.fn}"
      p -> "task → #{spec.service}: #{p}"
    end
  end

  defp running_detail(%{spec: spec}), do: Map.get(spec, :lang, "")

  defp prompt_of(%{args: %{"prompt" => p}}) when is_binary(p), do: p
  defp prompt_of(_), do: nil
end
