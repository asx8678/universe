defmodule UniverseWeb.WorkerLive do
  @moduledoc """
  One worker: its card, code file, live stdout/stderr tails, events and the
  handles it created. Works for workers from before a restart too (it reads
  the event log and the run directory).
  """

  use UniverseWeb, :live_view

  import UniverseWeb.TickComponents, only: [status_class: 1]

  alias Universe.{EventLog, Worker}

  @tail_lines 200

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Integer.parse(id) do
      {id, ""} ->
        if connected?(socket), do: Phoenix.PubSub.subscribe(Universe.PubSub, EventLog.topic())
        {:ok, socket |> assign(:id, id) |> assign(:page_title, "##{id}") |> load()}

      _ ->
        {:ok, socket |> put_flash(:error, "No such worker") |> push_navigate(to: ~p"/workers")}
    end
  end

  @impl true
  def handle_info({:event, %{"id" => id}}, %{assigns: %{id: id}} = socket),
    do: {:noreply, load(socket)}

  def handle_info({:event, _}, socket), do: {:noreply, socket}

  defp load(socket) do
    id = socket.assigns.id
    events = EventLog.for_id(id)
    spawn = Enum.find(events, &(&1["type"] == "spawn"))
    exit = events |> Enum.filter(&(&1["type"] == "exit")) |> List.last()
    first = List.first(events)
    live = Map.get(Universe.Tick.snapshot(), id)
    dir = Worker.run_dir(id)

    assign(socket,
      events: Enum.take(events, -300),
      label:
        (first && get_in(first, ["data", "label"])) || (spawn && spawn["data"]["label"]) || "?",
      kind: (spawn && spawn["data"]["kind"]) || (first && first["data"]["kind"]) || "?",
      status: (live && live.status) || (exit && exit["data"]["status"]) || "unknown",
      exit: exit && exit["data"],
      code: read_code(dir, spawn),
      stdout: tail(Path.join(dir, "stdout")),
      stderr: tail(Path.join(dir, "stderr")),
      handles: for(e <- events, e["type"] == "put", do: e["data"])
    )
  end

  defp read_code(_dir, nil), do: nil

  defp read_code(dir, spawn) do
    case File.read(Path.join(dir, Worker.code_file(spawn["data"]["lang"]))) do
      {:ok, text} -> text
      _ -> nil
    end
  end

  defp tail(path) do
    case File.read(path) do
      {:ok, text} ->
        text |> Worker.utf8() |> String.split("\n") |> Enum.take(-@tail_lines) |> Enum.join("\n")

      _ ->
        ""
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-wrap items-center gap-3">
        <.link navigate={~p"/workers"} class="btn btn-ghost btn-sm">← Workers</.link>
        <h1 class="text-lg font-semibold font-mono">#{@id} {@label}</h1>
        <span class="badge">{@kind}</span>
        <span class={["badge", status_class(@status)]}>{@status}</span>
      </div>

      <pre :if={@exit} class="text-xs rounded bg-base-200 p-2 overflow-x-auto"><code>{Jason.encode!(@exit, pretty: true)}</code></pre>

      <section :if={@handles != []} class="space-y-1">
        <h2 class="text-xs uppercase tracking-wide opacity-60">Handles</h2>
        <ul class="text-sm font-mono">
          <li :for={h <- @handles}>{h["handle"]} · {h["kind"]} · {h["summary"]}</li>
        </ul>
      </section>

      <section :if={@code} class="space-y-1">
        <h2 class="text-xs uppercase tracking-wide opacity-60">Code</h2>
        <pre class="text-xs rounded bg-base-200 p-2 overflow-x-auto max-h-96"><code>{@code}</code></pre>
      </section>

      <div class="grid md:grid-cols-2 gap-4">
        <section class="space-y-1 min-w-0">
          <h2 class="text-xs uppercase tracking-wide opacity-60">stdout (last 200 lines)</h2>
          <pre id="stdout" class="text-xs rounded bg-base-200 p-2 overflow-auto max-h-96"><code>{@stdout}</code></pre>
        </section>
        <section class="space-y-1 min-w-0">
          <h2 class="text-xs uppercase tracking-wide opacity-60">stderr (last 200 lines)</h2>
          <pre id="stderr" class="text-xs rounded bg-base-200 p-2 overflow-auto max-h-96"><code>{@stderr}</code></pre>
        </section>
      </div>

      <section class="space-y-1">
        <h2 class="text-xs uppercase tracking-wide opacity-60">Events</h2>
        <div class="overflow-x-auto">
          <table class="table table-xs font-mono">
            <tbody>
              <tr :for={e <- @events}>
                <td>{e["seq"]}</td>
                <td>{e["type"]}</td>
                <td class="max-w-xl truncate">{Jason.encode!(e["data"])}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
