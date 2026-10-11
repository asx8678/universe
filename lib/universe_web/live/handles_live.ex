defmodule UniverseWeb.HandlesLive do
  @moduledoc """
  Every stored handle, grouped by the worker that stored it (newest worker
  first), with kind, summary and size; click one for a preview.
  """

  use UniverseWeb, :live_view

  alias Universe.{Handles, Tick}

  # Groups open on load; older ones start folded.
  @open_groups 3

  @impl true
  def mount(_params, _session, socket) do
    handles = Handles.list()
    labels = Map.new(Tick.snapshot(), fn {id, w} -> {id, w.label} end)

    groups =
      handles
      |> Enum.group_by(&owner/1)
      |> Enum.map(fn {id, hs} ->
        %{
          id: id,
          label: labels[id],
          handles: Enum.sort_by(hs, &natural(&1["handle"])),
          bytes: hs |> Enum.map(&(&1["bytes"] || 0)) |> Enum.sum()
        }
      end)
      |> Enum.sort_by(&(&1.id || -1), :desc)

    {:ok,
     socket
     |> assign(:page_title, "Handles")
     |> assign(:groups, groups)
     |> assign(:count, length(handles))
     |> assign(:open_groups, @open_groups)
     |> assign(:selected, nil)
     |> assign(:preview, nil)}
  end

  # batch2 before batch10.
  defp natural(handle) do
    Regex.split(~r/(\d+)/, handle, include_captures: true)
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {n, ""} -> {0, n}
        _ -> {1, part}
      end
    end)
  end

  defp owner(%{"handle" => "h:" <> rest}) do
    case Integer.parse(rest) do
      {id, "/" <> _} -> id
      _ -> nil
    end
  end

  defp owner(_), do: nil

  @impl true
  def handle_event("preview", %{"handle" => handle}, socket) do
    preview =
      case Handles.preview(handle) do
        {:ok, text} -> text
        {:error, reason} -> reason
      end

    {:noreply, assign(socket, selected: handle, preview: preview)}
  end

  def handle_event("close", _params, socket),
    do: {:noreply, assign(socket, selected: nil, preview: nil)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={:handles}>
      <.page_header title="Handles">
        <:meta><span class="text-sm tabular-nums text-muted">{@count}</span></:meta>
        <:subtitle>
          Values workers stored with <code class="font-mono text-xs">U.put</code>, by worker.
          Click one to preview it.
        </:subtitle>
      </.page_header>

      <.empty :if={@groups == []}>No handles yet.</.empty>

      <div
        :if={@groups != []}
        class={["grid items-start gap-6", @preview && "lg:grid-cols-[minmax(0,1fr)_minmax(0,32rem)]"]}
      >
        <div class="min-w-0 space-y-3">
          <details
            :for={{g, i} <- Enum.with_index(@groups)}
            id={"group-#{g.id || "other"}"}
            open={i < @open_groups}
            class="group overflow-hidden rounded-xl border border-base-300 bg-base-100"
          >
            <summary class="flex cursor-pointer list-none items-center gap-2 px-4 py-2.5 transition hover:bg-base-200/50">
              <.icon
                name="hero-chevron-right-micro"
                class="size-4 text-muted transition group-open:rotate-90"
              />
              <span :if={g.id} class="font-mono text-xs text-muted">#{g.id}</span>
              <span class="font-medium">{g.label || (g.id && "worker") || "other"}</span>
              <span class="ml-auto text-xs tabular-nums text-muted">
                {length(g.handles)} · {Handles.human_bytes(g.bytes)}
              </span>
            </summary>
            <table class="w-full table-fixed border-t border-base-300 text-sm">
              <tbody>
                <tr
                  :for={h <- g.handles}
                  id={"h-" <> String.replace(h["handle"], ~r/[^A-Za-z0-9]/, "-")}
                  class={[
                    "cursor-pointer border-t border-base-300/60 transition first:border-0",
                    @selected == h["handle"] && "bg-primary/8",
                    @selected != h["handle"] && "hover:bg-base-200/50"
                  ]}
                  phx-click="preview"
                  phx-value-handle={h["handle"]}
                >
                  <td class={[td_class(), "w-56 max-w-56 truncate font-mono text-xs"]}>
                    {name(h["handle"])}
                  </td>
                  <td class={[td_class(), "w-20 whitespace-nowrap text-xs text-muted"]}>
                    {h["kind"]}
                  </td>
                  <td class={[td_class(), "break-words"]}>{h["summary"]}</td>
                  <td class={[
                    td_class(),
                    "w-0 whitespace-nowrap text-right text-xs tabular-nums text-muted"
                  ]}>
                    {Handles.human_bytes(h["bytes"])}
                  </td>
                </tr>
              </tbody>
            </table>
          </details>
        </div>

        <aside
          :if={@preview}
          id="preview"
          class="min-w-0 space-y-2 lg:sticky lg:top-20"
        >
          <div class="flex items-center justify-between gap-2">
            <code class="truncate font-mono text-xs font-medium">{@selected}</code>
            <.action variant={:ghost} phx-click="close" title="Close preview">
              <.icon name="hero-x-mark-micro" class="size-4" />
            </.action>
          </div>
          <.code_block class="max-h-[calc(100vh-10rem)]">{@preview}</.code_block>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  defp name("h:" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [_id, name] -> name
      _ -> "h:" <> rest
    end
  end

  defp name(handle), do: handle
end
