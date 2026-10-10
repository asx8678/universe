defmodule UniverseWeb.HandlesLive do
  @moduledoc "Every stored handle with kind, size and a preview on demand."

  use UniverseWeb, :live_view

  alias Universe.Handles

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Handles")
     |> assign(:handles, Handles.list() |> Enum.reverse())
     |> assign(:selected, nil)
     |> assign(:preview, nil)}
  end

  @impl true
  def handle_event("preview", %{"handle" => handle}, socket) do
    preview =
      case Handles.preview(handle) do
        {:ok, text} -> text
        {:error, reason} -> reason
      end

    {:noreply, assign(socket, selected: handle, preview: preview)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-lg font-semibold">Handles</h1>
      <div class="grid md:grid-cols-2 gap-4">
        <div class="overflow-x-auto rounded-box border border-base-300">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Handle</th><th>Kind</th><th>Summary</th><th>Size</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={h <- @handles}
                id={"h-" <> String.replace(h["handle"], ~r/[^A-Za-z0-9]/, "-")}
                class={["hover cursor-pointer", @selected == h["handle"] && "bg-base-200"]}
                phx-click="preview"
                phx-value-handle={h["handle"]}
              >
                <td class="font-mono">{h["handle"]}</td>
                <td>{h["kind"]}</td>
                <td class="text-xs">{h["summary"]}</td>
                <td class="text-xs">{Handles.human_bytes(h["bytes"])}</td>
              </tr>
            </tbody>
          </table>
          <p :if={@handles == []} class="text-sm opacity-60 p-6 text-center">No handles yet.</p>
        </div>
        <pre :if={@preview} class="text-xs rounded bg-base-200 p-3 overflow-auto"><code>{@preview}</code></pre>
      </div>
    </Layouts.app>
    """
  end
end
