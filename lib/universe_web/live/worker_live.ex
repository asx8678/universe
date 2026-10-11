defmodule UniverseWeb.WorkerLive do
  @moduledoc """
  One worker: its card, code file, live stdout/stderr tails, events and the
  handles it created. Works for workers from before a restart too (it reads
  the event log and the run directory).
  """

  use UniverseWeb, :live_view

  alias Universe.{Digest, EventLog, Worker}
  alias UniverseWeb.Activity

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
      tasks: if(agent && service, do: Activity.agent_tasks(service), else: []),
      events: events |> Enum.take(-300) |> Enum.reverse(),
      started: (spawn || first) && (spawn || first)["ts"],
      lang: spawn && spawn["data"]["lang"],
      service: service,
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
    <Layouts.app flash={@flash} page={:workers}>
      <.page_header title={@label} back={~p"/workers"} back_label="Workers">
        <:meta>
          <span class="font-mono text-sm text-muted">#{@id}</span>
          <.badge status={@status} />
        </:meta>
      </.page_header>

      <div class="rounded-xl border border-base-300 bg-base-100 p-4">
        <.kv id="summary">
          <:item label="Kind">{kind_text(@kind, @lang, @agent)}</:item>
          <:item :if={@service} label="Serves" mono>{@service}</:item>
          <:item label="Started"><.stamp ts={@started} /></:item>
          <:item :if={@exit && @exit["wall_ms"]} label="Ran for">
            {Digest.duration(@exit["wall_ms"])}
          </:item>
          <:item :if={@exit && (@exit["code"] || @exit["signal"])} label="Exit">
            {exit_text(@exit)}
          </:item>
          <:item :if={@exit && @exit["handle"]} label="Result" mono>{@exit["handle"]}</:item>
        </.kv>
        <div
          :if={@exit && @exit["reason"]}
          class={[
            "mt-4 rounded-lg border px-3 py-2",
            @status in ~w(failed budget) && "border-error/30 bg-error/6 text-error",
            @status not in ~w(failed budget) && "border-base-300 bg-base-200/50"
          ]}
        >
          <div class="text-xs font-medium opacity-80">Reason</div>
          <p phx-no-format class="mt-0.5 whitespace-pre-wrap break-words">{@exit["reason"]}</p>
        </div>
        <div :if={@exit && @exit["result_text"] && !@agent} class="mt-4">
          <div class="text-xs text-muted">Result</div>
          <.code_block class="mt-1 max-h-60" wrap>
            {Activity.result_text(@exit["result_text"])}
          </.code_block>
        </div>
        <div :if={@exit && @exit["last_err"] && @status in ~w(failed budget)} class="mt-4">
          <div class="text-xs text-muted">Last error line</div>
          <.code_block class="mt-1 max-h-40" wrap>{@exit["last_err"]}</.code_block>
        </div>
      </div>

      <section :if={@agent} id="agent" class="space-y-6">
        <.panel title="Purpose">
          <div class="rounded-xl border border-base-300 bg-base-100 p-4">
            <p phx-no-format class="whitespace-pre-wrap leading-relaxed">{@agent["purpose"]}</p>
            <div class="mt-3 flex flex-wrap gap-1.5 text-xs">
              <span class="rounded-md bg-base-200 px-2 py-0.5">{@agent["model"] || "default model"}</span>
              <span :if={(@agent["tools"] || []) != []} class="rounded-md bg-base-200 px-2 py-0.5">
                tools: {Enum.join(@agent["tools"], ", ")}
              </span>
              <span
                :if={(@agent["leases"] || []) != []}
                class="rounded-md bg-base-200 px-2 py-0.5 font-mono"
              >
                leases: {Enum.join(@agent["leases"], ", ")}
              </span>
            </div>
          </div>
        </.panel>

        <.panel title="Tasks" count={length(@tasks)}>
          <.empty :if={@tasks == []}>No tasks yet.</.empty>
          <ol id="agent-tasks" class="space-y-3">
            <li
              :for={t <- @tasks}
              id={"task-#{t.id}"}
              class="rounded-xl border border-base-300 bg-base-100 p-4"
            >
              <div class="flex items-center gap-2 text-xs">
                <.badge status={t.status} />
                <.link
                  navigate={~p"/workers/#{t.id}"}
                  class="font-mono text-muted hover:text-base-content hover:underline"
                >#{t.id}</.link>
                <span class="text-muted">{t.at}</span>
                <span :if={t.wall_ms} class="ml-auto tabular-nums text-muted">
                  {Digest.duration(t.wall_ms)}
                </span>
              </div>
              <p phx-no-format class="mt-2 whitespace-pre-wrap font-medium">{t.prompt}</p>
              <p
                :if={t.answer}
                phx-no-format
                class="mt-2 whitespace-pre-wrap rounded-lg bg-base-200/60 p-3 leading-relaxed"
              >{t.answer}</p>
              <p :if={t.handle} class="mt-2 font-mono text-xs">→ {t.handle}</p>
              <p :if={t.reason} class="mt-2 text-error">{t.reason}</p>
            </li>
          </ol>
        </.panel>
      </section>

      <.panel :if={@handles != []} id="handles" title="Stored handles" count={length(@handles)}>
        <.table_frame>
          <tbody>
            <tr :for={h <- @handles}>
              <td class={[td_class(), "font-mono text-xs"]}>{h["handle"]}</td>
              <td class={[td_class(), "text-muted"]}>{h["kind"]}</td>
              <td class={td_class()}>{h["summary"]}</td>
            </tr>
          </tbody>
        </.table_frame>
      </.panel>

      <.panel :if={@code} id="code" title="Code">
        <.code_block class="max-h-[28rem]">{@code}</.code_block>
      </.panel>

      <.panel id="output" title="Output">
        <:actions><span class="text-xs text-muted">last 200 lines</span></:actions>
        <.empty :if={@stdout == "" and @stderr == ""}>No output.</.empty>
        <div class={["grid gap-4", (@stdout != "" and @stderr != "") && "lg:grid-cols-2"]}>
          <div :if={@stdout != ""} class="min-w-0 space-y-1">
            <div class="text-xs text-muted">stdout</div>
            <.code_block id="stdout">{@stdout}</.code_block>
          </div>
          <div :if={@stderr != ""} class="min-w-0 space-y-1">
            <div class="text-xs text-error">stderr</div>
            <.code_block id="stderr">{@stderr}</.code_block>
          </div>
        </div>
      </.panel>

      <.panel id="events" title="Events" count={length(@events)}>
        <:actions><span class="text-xs text-muted">newest first · click for raw data</span></:actions>
        <ol class="divide-y divide-base-300/60 overflow-hidden rounded-xl border border-base-300 bg-base-100">
          <li :for={e <- @events} id={"event-#{e["seq"]}"}>
            <details class="group">
              <summary class="grid cursor-pointer list-none grid-cols-[4.25rem_5rem_minmax(0,1fr)] gap-x-2 px-3 py-1.5 text-[13px] leading-5 transition hover:bg-base-200/50">
                <%= with r <- Activity.describe(e) do %>
                  <span
                    class="text-xs leading-5 tabular-nums text-muted"
                    title={UniverseWeb.Format.full(r.ts)}
                  >{r.at}</span>
                  <span class={["truncate text-xs font-medium leading-5", tone_text(r.tone)]}>{r.type}</span>
                  <span class={[
                    "break-words",
                    r.tone == :muted && "text-muted",
                    r.tone == :bad && "text-error"
                  ]}>{r.text}</span>
                <% end %>
              </summary>
              <.code_block class="mx-3 mb-2 max-h-72" wrap>
                {Jason.encode!(e["data"], pretty: true)}
              </.code_block>
            </details>
          </li>
        </ol>
      </.panel>
    </Layouts.app>
    """
  end

  defp kind_text(_kind, _lang, %{} = agent), do: "agent · #{agent["model"] || "default model"}"
  defp kind_text("serve", lang, _), do: Enum.join(Enum.filter(["service", lang], & &1), " · ")
  defp kind_text(kind, lang, _), do: Enum.join(Enum.filter([kind, lang], & &1), " · ")

  defp exit_text(%{"signal" => sig}) when is_integer(sig) or is_binary(sig), do: "signal #{sig}"
  defp exit_text(%{"code" => code}), do: "code #{code}"
end
