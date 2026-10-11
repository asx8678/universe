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

  # An agent's tasks are other IDs' calls: follow those too.
  def handle_info({:event, %{"type" => t}}, %{assigns: %{agent: %{}}} = socket)
      when t in ["call", "exit"],
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
    code = read_code(dir, spawn)
    agent = agent_config(spawn, code)
    serve = Enum.find(events, &(&1["type"] == "serve"))
    service = (serve && serve["data"]["name"]) || (agent && agent["service"])

    assign(socket,
      agent: agent,
      tasks: if(agent && service, do: UniverseWeb.Activity.agent_tasks(service), else: []),
      events: Enum.take(events, -300),
      label:
        (first && get_in(first, ["data", "label"])) || (spawn && spawn["data"]["label"]) || "?",
      kind: (spawn && spawn["data"]["kind"]) || (first && first["data"]["kind"]) || "?",
      status: (live && live.status) || (exit && exit["data"]["status"]) || "unknown",
      exit: exit && exit["data"],
      code: if(agent, do: nil, else: code),
      stdout: tail(Path.join(dir, "stdout")),
      stderr: tail(Path.join(dir, "stderr")),
      handles: for(e <- events, e["type"] == "put", do: e["data"])
    )
  end

  defp agent_config(%{"data" => %{"lang" => "agent"}}, code) when is_binary(code) do
    case Jason.decode(code) do
      {:ok, %{} = cfg} -> cfg
      _ -> nil
    end
  end

  defp agent_config(_, _), do: nil

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

      <section :if={@agent} id="agent" class="space-y-4">
        <div class="rounded-xl border border-base-300 bg-base-100 p-4 space-y-2">
          <div class="flex flex-wrap gap-2 text-xs">
            <span class="rounded-full bg-base-200 px-2 py-0.5">{@agent["model"] || "default model"}</span>
            <span class="rounded-full bg-base-200 px-2 py-0.5">tools: {Enum.join(
              @agent["tools"] || [],
              ", "
            )}</span>
            <span :if={(@agent["leases"] || []) != []} class="rounded-full bg-base-200 px-2 py-0.5">
              leases: {Enum.join(@agent["leases"], ", ")}
            </span>
          </div>
          <h2 class="text-xs font-medium uppercase tracking-wide opacity-60">Purpose</h2>
          <p phx-no-format class="text-sm whitespace-pre-wrap">{@agent["purpose"]}</p>
        </div>

        <div class="space-y-2">
          <h2 class="text-xs font-medium uppercase tracking-wide opacity-60">
            Tasks · {length(@tasks)}
          </h2>
          <p :if={@tasks == []} class="text-sm opacity-60">No tasks yet.</p>
          <ol id="agent-tasks" class="space-y-2">
            <li
              :for={t <- @tasks}
              id={"task-#{t.id}"}
              class="rounded-xl border border-base-300 bg-base-100 p-3 text-sm"
            >
              <div class="flex items-center gap-2 text-xs">
                <.link navigate={~p"/workers/#{t.id}"} class="font-mono hover:underline">#{t.id}</.link>
                <span class="opacity-50">{t.at}</span>
                <span class={["badge badge-xs", status_class(t.status)]}>{t.status}</span>
                <span :if={t.wall_ms} class="ml-auto font-mono opacity-60">
                  {Universe.Digest.duration(t.wall_ms)}
                </span>
              </div>
              <p phx-no-format class="mt-1.5 font-medium whitespace-pre-wrap">{t.prompt}</p>
              <p
                :if={t.answer}
                phx-no-format
                class="mt-1.5 whitespace-pre-wrap rounded-lg bg-base-200 p-2"
              >{t.answer}</p>
              <p :if={t.handle} class="mt-1.5 font-mono text-xs">→ {t.handle}</p>
              <p :if={t.reason} class="mt-1.5 text-error">{t.reason}</p>
            </li>
          </ol>
        </div>
      </section>

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
