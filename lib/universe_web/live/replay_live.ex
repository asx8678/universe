defmodule UniverseWeb.ReplayLive do
  @moduledoc """
  Offline replay of any saved event log in `.universe/log/` (`*.jsonl`):
  the same tick cards as the live timeline, read from the file alone.
  """

  use UniverseWeb, :live_view

  import UniverseWeb.TickComponents

  alias Universe.Paths

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Replay", files: log_files())}

  # Picking a file patches the URL, so the file is read here, not in mount.
  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case params["file"] do
        nil ->
          assign(socket, file: nil, ticks: [], error: nil)

        file ->
          if file in socket.assigns.files do
            assign(socket, file: file, ticks: ticks_from_events(read(file)), error: nil)
          else
            assign(socket, file: file, ticks: [], error: "no log named #{file}")
          end
      end

    {:noreply, socket}
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
    <Layouts.app flash={@flash} page={:replay}>
      <.page_header title="Replay">
        <:subtitle>
          Saved event logs in <code class="font-mono text-xs">.universe/log/</code>, read from the file alone.
        </:subtitle>
      </.page_header>
      <.empty :if={@files == []}>No saved logs yet.</.empty>
      <.seg
        :if={@files != []}
        id="replay-files"
        options={for f <- @files, do: {f, f}}
        value={@file}
        patch={&~p"/replay/#{&1}"}
      />
      <p :if={@error} class="text-error">{@error}</p>
      <.empty :if={@file && @ticks == [] && !@error}>No ticks in {@file}.</.empty>
      <.empty :if={is_nil(@file) and @files != []}>Pick a log to replay its ticks.</.empty>
      <div class="space-y-4">
        <.tick_card :for={t <- @ticks} id={"replay-" <> t.id} tick={t} />
      </div>
    </Layouts.app>
    """
  end
end
