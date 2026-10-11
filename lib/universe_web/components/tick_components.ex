defmodule UniverseWeb.TickComponents do
  @moduledoc """
  The tick card shared by the live timeline and offline replay: directives
  the model sent, the digest it got back, token estimates, wait and wake.
  """

  use Phoenix.Component

  import UniverseWeb.CoreComponents, only: [icon: 1]
  import UniverseWeb.UIComponents

  alias Universe.Digest

  @doc "Builds a tick card's data from its `tick_in`/`tick_out` events."
  def build_tick(tick, events) do
    tin = Enum.find(events, &(&1 && &1["type"] == "tick_in"))
    tout = Enum.find(events, &(&1 && &1["type"] == "tick_out"))
    directives = List.wrap(tin && tin["data"]["directives"])

    %{
      id: "t#{tick}",
      tick: tick,
      at: tin && tin["ts"],
      directives: directives,
      wait: tin && tin["data"]["wait"],
      tokens_in: Digest.estimate_tokens(Jason.encode!(tin && tin["data"])),
      digest: tout && tout["data"]["text"],
      tokens_out: tout && tout["data"]["tokens_out_est"],
      wake: tout && tout["data"]["wake"],
      wait_ms: tout && tout["data"]["wait_ms"]
    }
  end

  @doc "Groups a list of events into tick cards, newest first."
  def ticks_from_events(events) do
    events
    |> Enum.filter(&(&1["type"] in ["tick_in", "tick_out"]))
    |> Enum.group_by(& &1["tick"])
    |> Enum.map(fn {tick, evs} -> build_tick(tick, evs) end)
    |> Enum.sort_by(& &1.tick, :desc)
  end

  attr :id, :string, required: true
  attr :tick, :map, required: true
  attr :flow_link, :boolean, default: false, doc: "link to the tick's flow diagram"

  def tick_card(assigns) do
    assigns = assign(assigns, :digest, parse_digest(assigns.tick.digest))

    ~H"""
    <article id={@id} class="overflow-hidden rounded-xl border border-base-300 bg-base-100">
      <header class="flex flex-wrap items-center gap-x-3 gap-y-1.5 border-b border-base-300 bg-base-200/40 px-4 py-2.5">
        <span class="font-mono text-sm font-semibold">t{@tick.tick}</span>
        <.stamp ts={@tick.at} class="text-xs text-muted" />
        <.badge :if={@tick.wake} status={@tick.wake} title={wake_hint(@tick.wake)} />
        <.badge :if={is_nil(@tick.wake)} status="running">waiting…</.badge>
        <span :if={@tick.wait_ms} class="text-xs text-muted">
          answered after {Digest.duration(@tick.wait_ms)}
        </span>
        <span class="ml-auto text-xs tabular-nums text-muted" title="estimated tokens (chars / 4)">
          ~{@tick.tokens_in} tokens in · ~{@tick.tokens_out || "…"} out
        </span>
        <.action
          :if={@flow_link}
          id={"flow-link-#{@tick.tick}"}
          navigate={"/timeline/#{@tick.tick}"}
        >
          <.icon name="hero-arrows-right-left-micro" class="size-3.5" /> Flow
        </.action>
      </header>

      <div class="grid divide-y divide-base-300 lg:grid-cols-[minmax(0,2fr)_minmax(0,3fr)] lg:divide-x lg:divide-y-0">
        <section class="min-w-0 space-y-3 p-4">
          <h3 class="text-xs font-medium text-muted">
            Model sent {count(length(@tick.directives), "directive")}
          </h3>
          <ul class="space-y-2">
            <li :for={d <- @tick.directives} class="min-w-0">
              <div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
                <code class="rounded bg-base-200 px-1.5 py-px font-mono text-xs font-medium">{op(d)}</code>
                <span class="font-medium">{label(d)}</span>
                <span class="text-xs text-muted">{meta(d)}</span>
              </div>
              <details :if={is_map(d) and is_binary(d["code"])} class="group mt-1.5">
                <summary class="inline-flex cursor-pointer list-none items-center gap-1 text-xs text-muted transition hover:text-base-content">
                  <.icon
                    name="hero-chevron-right-micro"
                    class="size-3.5 transition group-open:rotate-90"
                  /> code · {line_count(d["code"])}
                </summary>
                <.code_block class="mt-1.5 max-h-80">{d["code"]}</.code_block>
              </details>
            </li>
          </ul>
          <p :if={@tick.wait} class="flex items-start gap-1.5 text-xs text-muted">
            <.icon name="hero-clock-micro" class="mt-px size-3.5 shrink-0" />
            {wait_text(@tick.wait)}
          </p>
        </section>

        <section class="min-w-0 space-y-3 p-4">
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <h3 class="text-xs font-medium text-muted">Universe answered</h3>
            <span :if={@digest} class="text-xs text-muted">{@digest.header}</span>
          </div>
          <p :if={is_nil(@tick.digest)} class="text-muted">Waiting for a wake rule…</p>
          <ul :if={@digest} class="space-y-1">
            <li
              :for={row <- @digest.rows}
              class="grid grid-cols-[2.75rem_4.75rem_minmax(0,1fr)] items-baseline gap-x-2"
            >
              <%= case row do %>
                <% {:row, id, status, label, detail} -> %>
                  <span class="font-mono text-xs text-muted">{id}</span>
                  <span><.badge status={status} /></span>
                  <span class="min-w-0 break-words">
                    <span class="font-medium">{label}</span>
                    <span class={["ml-1", status in ~w(done killed) && "text-muted"]}>{detail}</span>
                  </span>
                <% {:text, text} -> %>
                  <span class="col-span-3 break-words font-mono text-xs">{text}</span>
              <% end %>
            </li>
          </ul>
          <p :if={@digest && @digest.footer} class="text-xs text-muted">{@digest.footer}</p>
          <details :if={@tick.digest} class="group">
            <summary class="inline-flex cursor-pointer list-none items-center gap-1 text-xs text-muted transition hover:text-base-content">
              <.icon name="hero-chevron-right-micro" class="size-3.5 transition group-open:rotate-90" />
              exact text the model got
            </summary>
            <.code_block class="mt-1.5 max-h-96">{@tick.digest}</.code_block>
          </details>
        </section>
      </div>
    </article>
    """
  end

  @doc """
  Splits a digest's text into its header line, one entry per worker line
  (`{:row, id, status, label, detail}`, or `{:text, line}` when a line has
  another shape) and the footer (`+N auto-acked …`/`inspect(…)`).
  """
  def parse_digest(nil), do: nil

  def parse_digest(text) do
    [header | rest] = String.split(text, "\n")

    {footer, rows} =
      case List.last(rest) do
        nil -> {nil, []}
        last -> if footer?(last), do: {last, Enum.drop(rest, -1)}, else: {nil, rest}
      end

    %{header: header, footer: footer, rows: Enum.map(rows, &digest_row/1)}
  end

  defp footer?(line),
    do: String.contains?(line, "inspect(") and not String.starts_with?(line, "#")

  defp digest_row(line) do
    case Regex.run(~r/^(#\d+|--)\s+(\S+)\s+(\S+)\s*(.*)$/, line) do
      [_, id, status, label, detail] -> {:row, id, status, label, detail}
      _ -> {:text, line}
    end
  end

  @doc "A tick's wait as a sentence."
  def wait_text(wait) when is_map(wait) do
    ids = wait["ids"] |> List.wrap() |> Enum.map(&text/1)
    quantifier = if wait["until"] == "any", do: "any", else: "all"

    what =
      case ids do
        [] -> "Wakes when this tick's work settles"
        [one] -> "Wakes when #{one} settles"
        _ -> "Wakes when #{quantifier} of #{Enum.join(ids, ", ")} settle"
      end

    limit = if is_number(wait["timeout_s"]), do: " · at most #{wait["timeout_s"]}s", else: ""
    what <> limit <> ", or sooner if a worker needs attention"
  end

  def wait_text(_), do: ""

  defp wake_hint("settled"), do: "everything it waited for finished"
  defp wake_hint("attention"), do: "a worker failed or asked a question"
  defp wake_hint("timeout"), do: "the wait timed out; work goes on"
  defp wake_hint(_), do: nil

  defp count(1, word), do: "1 #{word}"
  defp count(n, word), do: "#{n} #{word}s"

  defp line_count(code) do
    n = code |> String.trim_trailing() |> String.split("\n") |> length()
    count(n, "line")
  end

  defp op(%{"op" => op}) when is_binary(op), do: op
  defp op(_), do: "?"

  defp label(%{"label" => l}) when is_binary(l), do: l
  defp label(%{"target" => t}) when is_binary(t), do: t
  defp label(_), do: ""

  defp meta(d) when is_map(d) do
    [
      d["lang"],
      is_binary(d["service"]) && "#{d["service"]}.#{text(d["fn"])}",
      (is_list(d["after"]) and d["after"] != []) &&
        "after #{Enum.map_join(d["after"], ", ", &text/1)}",
      (is_list(d["leases"]) and d["leases"] != []) &&
        "leases #{Enum.map_join(d["leases"], ", ", &text/1)}",
      (is_list(d["then"]) and d["then"] != []) && "then #{length(d["then"])}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp meta(_), do: ""

  # A logged value as text. `tick_in` keeps directives (and, in older logs,
  # waits) as the model sent them, before validation, so they may hold any
  # JSON value: a map where a label belongs must not crash the page.
  defp text(v) when is_binary(v), do: v
  defp text(nil), do: ""
  defp text(v) when is_number(v) or is_boolean(v), do: to_string(v)
  defp text(v), do: Jason.encode!(v)
end
