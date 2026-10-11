defmodule UniverseWeb.ReplayLive do
  @moduledoc """
  Offline replay of any saved event log in `.universe/log/` (`*.jsonl`):
  the same tick cards as the live timeline, read from the file alone.
  """

  use UniverseWeb, :live_view

  import UniverseWeb.TickComponents

  alias Universe.Paths

  # Logs bigger than this are not replayed in the browser.
  @max_bytes 256 * 1024 * 1024

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Replay")}

  # Picking a file patches the URL, so the file is read here, not in mount;
  # the list is re-read too, since logs come and go.
  @impl true
  def handle_params(params, _uri, socket) do
    files = log_files()
    socket = assign(socket, files: files)

    socket =
      case params["file"] do
        nil ->
          assign(socket, file: nil, ticks: [], error: nil)

        file ->
          if file in files do
            case read(file) do
              {:ok, events} ->
                assign(socket, file: file, ticks: ticks_from_events(events), error: nil)

              {:error, reason} ->
                assign(socket, file: file, ticks: [], error: reason)
            end
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

  # Streams the file and keeps only tick_in/tick_out events: a replay never
  # holds a whole log in the LiveView's memory.
  defp read(file) do
    path = Path.join(Paths.log_dir(), file)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > @max_bytes ->
        {:error, "#{file} is over #{div(@max_bytes, 1_048_576)} MB; too big to replay here"}

      {:ok, _} ->
        try do
          events =
            path
            |> File.stream!()
            |> Stream.filter(&String.contains?(&1, "\"tick_"))
            |> Stream.flat_map(fn line ->
              case Jason.decode(line) do
                {:ok, %{"type" => t} = e} when t in ["tick_in", "tick_out"] -> [e]
                _ -> []
              end
            end)
            |> Enum.to_list()

          {:ok, events}
        rescue
          e in File.Error -> {:error, "cannot read #{file}: #{Exception.message(e)}"}
        end

      {:error, reason} ->
        {:error, "cannot read #{file}: #{reason}"}
    end
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
