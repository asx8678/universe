defmodule UniverseWeb.TickComponents do
  @moduledoc """
  The tick card shared by the live timeline and offline replay: directives
  the model sent, the digest it got back, token estimates, wait and wake.
  """

  use Phoenix.Component

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

  def tick_card(assigns) do
    ~H"""
    <article id={@id} class="rounded-box border border-base-300 bg-base-100">
      <header class="flex flex-wrap items-center gap-x-4 gap-y-1 px-4 py-2 border-b border-base-300 text-sm">
        <span class="font-mono font-semibold">t{@tick.tick}</span>
        <span class="opacity-60 font-mono text-xs">{@tick.at}</span>
        <span :if={@tick.wake} class={["badge badge-sm", wake_class(@tick.wake)]}>{@tick.wake}</span>
        <span :if={is_nil(@tick.wake)} class="badge badge-sm badge-ghost">waiting…</span>
        <span :if={@tick.wait_ms} class="opacity-70">waited {Digest.duration(@tick.wait_ms)}</span>
        <span class="ml-auto font-mono text-xs opacity-70">
          ~{@tick.tokens_in} tok in → ~{@tick.tokens_out || "…"} tok out
        </span>
      </header>

      <div class="grid md:grid-cols-2 divide-y md:divide-y-0 md:divide-x divide-base-300">
        <section class="p-4 space-y-2 min-w-0">
          <h2 class="text-xs uppercase tracking-wide opacity-60">
            Model → Universe · {length(@tick.directives)} directive(s)
            <span :if={@tick.wait} class="normal-case font-mono">· wait {Jason.encode!(@tick.wait)}</span>
          </h2>
          <div :for={d <- @tick.directives} class="text-sm">
            <div class="font-mono">
              <span class="font-semibold">{op(d)}</span>
              <span>{label(d)}</span>
              <span class="opacity-60">{meta(d)}</span>
            </div>
            <details :if={is_map(d) and is_binary(d["code"])} class="mt-1">
              <summary class="cursor-pointer text-xs opacity-60">code</summary>
              <pre class="mt-1 overflow-x-auto rounded bg-base-200 p-2 text-xs"><code>{d["code"]}</code></pre>
            </details>
          </div>
        </section>

        <section class="p-4 space-y-2 min-w-0">
          <h2 class="text-xs uppercase tracking-wide opacity-60">Universe → model · digest</h2>
          <pre :if={@tick.digest} class="overflow-x-auto text-xs leading-relaxed"><code>{@tick.digest}</code></pre>
          <p :if={is_nil(@tick.digest)} class="text-sm opacity-60">waiting for a wake rule…</p>
        </section>
      </div>
    </article>
    """
  end

  defp op(%{"op" => op}) when is_binary(op), do: op
  defp op(_), do: "?"

  defp label(%{"label" => l}) when is_binary(l), do: l
  defp label(%{"target" => t}) when is_binary(t), do: t
  defp label(_), do: ""

  defp meta(d) when is_map(d) do
    [
      d["lang"],
      is_binary(d["service"]) && "#{d["service"]}.#{d["fn"]}",
      (is_list(d["after"]) and d["after"] != []) && "after #{Enum.join(d["after"], ", ")}",
      (is_list(d["leases"]) and d["leases"] != []) && "leases #{Enum.join(d["leases"], ", ")}",
      (is_list(d["then"]) and d["then"] != []) && "then #{length(d["then"])}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp meta(_), do: ""

  def wake_class("settled"), do: "badge-success"
  def wake_class("attention"), do: "badge-warning"
  def wake_class("timeout"), do: "badge-info"
  def wake_class(_), do: "badge-ghost"

  def status_class(s) when s in ["failed", "budget"], do: "badge-error"
  def status_class("asking"), do: "badge-warning"
  def status_class(s) when s in ["running", "queued"], do: "badge-info"
  def status_class("serving"), do: "badge-accent"
  def status_class("done"), do: "badge-success"
  def status_class(_), do: "badge-ghost"
end
