defmodule UniverseWeb.WorkersLive do
  @moduledoc """
  Live process table: every worker the Tick knows, newest first, with kind,
  status, timing, budget and leases. Refreshes (throttled) on new events.
  """

  use UniverseWeb, :live_view

  alias Universe.{Digest, EventLog, Tick}

  @refresh_ms 300
  @page 50
  @live ~w(queued running serving asking)
  @statuses [{"all", "All"}, {"live", "Live"}, {"failed", "Failed"}, {"done", "Done"}]
  @kinds [
    {"all", "Any kind"},
    {"run", "Runs"},
    {"serve", "Services"},
    {"agent", "Agents"},
    {"call", "Calls"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Universe.PubSub, EventLog.topic())

    {:ok,
     assign(socket,
       page_title: "Workers",
       pending: false,
       status: "all",
       kind: "all",
       limit: @page
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = pick(params["status"], @statuses)
    kind = pick(params["kind"], @kinds)
    {:noreply, socket |> assign(status: status, kind: kind, limit: @page) |> load()}
  end

  defp pick(value, options),
    do: if(Enum.any?(options, &(elem(&1, 0) == value)), do: value, else: "all")

  @impl true
  def handle_event("stop_all", _params, socket) do
    {:ok, n} = Tick.stop_all()
    {:noreply, socket |> put_flash(:info, "Stopped #{n} live worker(s).") |> load()}
  end

  def handle_event("more", _params, socket),
    do: {:noreply, socket |> update(:limit, &(&1 + @page)) |> load()}

  @impl true
  def handle_info({:event, _}, %{assigns: %{pending: true}} = socket), do: {:noreply, socket}

  def handle_info({:event, _}, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, :pending, true)}
  end

  def handle_info(:refresh, socket), do: {:noreply, socket |> assign(:pending, false) |> load()}

  defp load(socket) do
    %{status: status, kind: kind, limit: limit} = socket.assigns
    all = Tick.snapshot() |> Map.values() |> Enum.sort_by(& &1.id, :desc)
    of_kind = Enum.filter(all, &(kind == "all" or kind_of(&1) == kind))
    shown = Enum.filter(of_kind, &in_status?(&1, status))
    leases = Tick.leases()

    assign(socket,
      workers: Enum.take(shown, limit),
      matching: length(shown),
      total: length(all),
      counts: Map.new(@statuses, fn {s, _} -> {s, Enum.count(of_kind, &in_status?(&1, s))} end),
      leases: leases,
      any_leases?: Enum.any?(leases, fn {_id, paths} -> paths != [] end)
    )
  end

  defp in_status?(_w, "all"), do: true
  defp in_status?(w, "live"), do: w.status in @live
  defp in_status?(w, "failed"), do: w.status in ["failed", "budget"]
  defp in_status?(w, "done"), do: w.status == "done"

  defp kind_of(w) do
    if match?(%{agent: %{}}, w.spec), do: "agent", else: w.kind
  end

  defp filter_path(assigns, changes) do
    params =
      %{status: assigns.status, kind: assigns.kind}
      |> Map.merge(changes)
      |> Enum.reject(fn {_k, v} -> v == "all" end)

    ~p"/workers?#{params}"
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        status_options: for({s, label} <- @statuses, do: {s, "#{label} #{assigns.counts[s]}"}),
        kind_options: @kinds
      )

    ~H"""
    <Layouts.app flash={@flash} page={:workers}>
      <.page_header title="Workers">
        <:meta><span class="text-sm tabular-nums text-muted">{@total}</span></:meta>
        <:subtitle>
          Every worker this daemon knows, newest first. Open one for its output, events and handles.
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

      <div class="flex flex-wrap items-center gap-2">
        <.seg
          id="status-filter"
          id_prefix="status-"
          options={@status_options}
          value={@status}
          patch={&filter_path(assigns, %{status: &1})}
        />
        <.seg
          id="kind-filter"
          id_prefix="kind-"
          options={@kind_options}
          value={@kind}
          patch={&filter_path(assigns, %{kind: &1})}
        />
      </div>

      <.empty :if={@workers == []}>
        {if @total == 0, do: "No workers yet.", else: "No workers match these filters."}
      </.empty>

      <.table_frame :if={@workers != []} id="workers">
        <thead>
          <tr>
            <th class={[th_class(), "w-16"]}>ID</th>
            <th class={th_class()}>Worker</th>
            <th class={th_class()}>Status</th>
            <th class={[th_class(), "text-right"]}>Time</th>
            <th class={th_class()}>Detail</th>
            <th :if={@any_leases?} class={th_class()}>Leases</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={w <- @workers}
            id={"worker-#{w.id}"}
            class="group transition hover:bg-base-200/50"
          >
            <td class={[td_class(), "font-mono text-xs"]}>
              <.link
                navigate={~p"/workers/#{w.id}"}
                class="text-muted hover:text-base-content hover:underline"
              >
                #{w.id}
              </.link>
            </td>
            <td class={td_class()}>
              <.link navigate={~p"/workers/#{w.id}"} class="font-medium hover:underline">{w.label}</.link>
              <div class="text-xs text-muted">{kind_text(w)}</div>
            </td>
            <td class={td_class()}><.badge status={w.status} /></td>
            <td class={[td_class(), "whitespace-nowrap text-right text-xs tabular-nums text-muted"]}>
              {elapsed(w)}
            </td>
            <td class={[td_class(), "max-w-xl"]}>
              <span
                :if={d = detail(w)}
                class={["line-clamp-2 break-words", detail_class(w)]}
                title={d}
              >
                {d}
              </span>
            </td>
            <td :if={@any_leases?} class={[td_class(), "font-mono text-xs"]}>
              {Enum.join(Map.get(@leases, w.id, []), ", ")}
            </td>
          </tr>
        </tbody>
      </.table_frame>

      <div :if={@matching > length(@workers)} class="flex items-center justify-center gap-3">
        <span class="text-xs text-muted">Showing {length(@workers)} of {@matching}</span>
        <.action id="workers-more" phx-click="more">
          Show {min(50, @matching - length(@workers))} more
        </.action>
      </div>
    </Layouts.app>
    """
  end

  defp kind_text(w) do
    lang = w.spec[:lang]

    case kind_of(w) do
      "agent" -> "agent · #{w.spec.agent.model || "default model"}"
      "serve" -> Enum.join(Enum.filter(["service", lang], & &1), " · ")
      "call" -> "call"
      kind -> Enum.join(Enum.filter([kind, lang], & &1), " · ")
    end
  end

  defp elapsed(%{summary: %{"wall_ms" => ms}}) when is_integer(ms), do: Digest.duration(ms)

  defp elapsed(%{started_ms: started, status: s})
       when is_integer(started) and s in ["running", "serving", "asking"],
       do: Digest.duration(System.monotonic_time(:millisecond) - started)

  defp elapsed(_), do: ""

  # Only what helps: what a live worker serves or asks, why one failed or
  # was stopped. Finished, healthy workers need no detail.
  defp detail(%{status: "serving"} = w), do: "serves #{w.service}: #{Enum.join(w.fns, ", ")}"
  defp detail(%{status: "asking"} = w), do: w.question

  defp detail(%{kind: "call", spec: spec}) when is_map_key(spec, :service),
    do: "#{spec[:service]}.#{spec[:fn]}"

  defp detail(%{status: s, summary: %{} = sum}) when s in ["failed", "budget", "killed"],
    do: sum["reason"] || sum["last_err"]

  defp detail(_), do: nil

  defp detail_class(%{status: s}) when s in ["failed", "budget"], do: "text-error"
  defp detail_class(%{status: "asking"}), do: "text-warning"
  defp detail_class(%{status: "killed"}), do: "text-muted"
  defp detail_class(_), do: nil
end
