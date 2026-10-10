defmodule UniverseWeb.ReplayLive do
  @moduledoc """
  Offline replay of any saved event log in `.universe/log/` (`*.jsonl`):
  the same tick cards as the live timeline, read from the file alone.
  """

  use UniverseWeb, :live_view

  import UniverseWeb.TickComponents

  alias Universe.Paths

  @impl true
  def mount(params, _session, socket) do
    files = log_files()

    socket =
      case params["file"] do
        nil ->
          assign(socket, file: nil, ticks: [], error: nil)

        file ->
          if file in files do
            assign(socket, file: file, ticks: ticks_from_events(read(file)), error: nil)
          else
            assign(socket, file: file, ticks: [], error: "no log named #{file}")
          end
      end

    {:ok, assign(socket, page_title: "Replay", files: files)}
  end

  defp log_files do
    case File.ls(Paths.log_dir()) do
      {:ok, files} -> files |> Enum.filter(&String.ends_with?(&1, ".jsonl")) |> Enum.sort()
      _ -> []
    end
  end

  defp read(file) do
    Path.join(Paths.log_dir(), file)
    |> File.stream!()
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{} = e} -> [e]
        _ -> []
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-lg font-semibold">Replay</h1>
      <div class="flex flex-wrap gap-2">
        <.link
          :for={f <- @files}
          navigate={~p"/replay/#{f}"}
          class={["btn btn-sm", if(f == @file, do: "btn-primary", else: "btn-ghost")]}
        >
          {f}
        </.link>
      </div>
      <p :if={@error} class="text-error text-sm">{@error}</p>
      <p :if={@file && @ticks == [] && !@error} class="text-sm opacity-60">No ticks in {@file}.</p>
      <div class="space-y-4">
        <.tick_card :for={t <- @ticks} id={"replay-" <> t.id} tick={t} />
      </div>
    </Layouts.app>
    """
  end
end
