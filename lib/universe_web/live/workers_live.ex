defmodule UniverseWeb.WorkersLive do
  @moduledoc """
  Live process table: every worker the Tick knows, newest first, with kind,
  status, timing, budget and leases. Refreshes (throttled) on new events.
  """

  use UniverseWeb, :live_view

  import UniverseWeb.TickComponents, only: [status_class: 1]

  alias Universe.{Digest, EventLog, Tick}

  @refresh_ms 300

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Universe.PubSub, EventLog.topic())
    {:ok, socket |> assign(:page_title, "Workers") |> assign(:pending, false) |> load()}
  end

  @impl true
  def handle_event("stop_all", _params, socket) do
    {:ok, n} = Tick.stop_all()
    {:noreply, socket |> put_flash(:info, "Stopped #{n} live worker(s).") |> load()}
  end

  @impl true
  def handle_info({:event, _}, %{assigns: %{pending: true}} = socket), do: {:noreply, socket}

  def handle_info({:event, _}, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, :pending, true)}
  end

  def handle_info(:refresh, socket), do: {:noreply, socket |> assign(:pending, false) |> load()}

  defp load(socket) do
    workers = Tick.snapshot() |> Map.values() |> Enum.sort_by(& &1.id, :desc)
    leases = Tick.leases()
    live = Enum.count(workers, &(&1.status in ["queued", "running", "serving", "asking"]))
    assign(socket, workers: workers, leases: leases, live: live)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h1 class="text-lg font-semibold">Workers</h1>
        <div class="flex items-center gap-3">
          <span class="text-sm opacity-60">{@live} live · {length(@workers)} tracked</span>
          <button
            phx-click="stop_all"
            data-confirm="Kill every live worker, service and call?"
            class="btn btn-error btn-sm"
          >
            Stop all
          </button>
        </div>
      </div>

      <div class="overflow-x-auto rounded-box border border-base-300">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>ID</th>
              <th>Label</th>
              <th>Kind</th>
              <th>Status</th>
              <th>Time</th>
              <th>Detail</th>
              <th>Leases</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={w <- @workers} id={"worker-#{w.id}"} class="hover">
              <td class="font-mono">
                <.link navigate={~p"/workers/#{w.id}"} class="link">#{w.id}</.link>
              </td>
              <td class="font-mono">{w.label}</td>
              <td>{w.kind}</td>
              <td><span class={["badge badge-sm", status_class(w.status)]}>{w.status}</span></td>
              <td class="font-mono text-xs">{elapsed(w)}</td>
              <td class="text-xs max-w-md truncate">{detail(w)}</td>
              <td class="font-mono text-xs">{Enum.join(Map.get(@leases, w.id, []), ", ")}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p :if={@workers == []} class="text-sm opacity-60 py-8 text-center">No workers yet.</p>
    </Layouts.app>
    """
  end

  defp elapsed(%{summary: %{"wall_ms" => ms}}) when is_integer(ms), do: Digest.duration(ms)

  defp elapsed(%{started_ms: started, status: s})
       when is_integer(started) and s in ["running", "serving", "asking"],
       do: Digest.duration(System.monotonic_time(:millisecond) - started)

  defp elapsed(_), do: ""

  defp detail(%{status: "serving"} = w), do: "#{w.service} · #{Enum.join(w.fns, ", ")}"
  defp detail(%{status: "asking"} = w), do: w.question
  defp detail(%{kind: "call", spec: spec}), do: "#{spec[:service]}.#{spec[:fn]}"
  defp detail(%{summary: %{"reason" => r}}) when is_binary(r), do: r
  defp detail(%{summary: %{"last_err" => e}}) when is_binary(e), do: e
  defp detail(%{summary: %{"last_out" => o}}) when is_binary(o), do: o
  defp detail(_), do: ""
end
