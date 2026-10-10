defmodule Universe.Ids do
  @moduledoc """
  Monotonic worker IDs (`#1`, `#2`, …) and tick numbers (`t1`, `t2`, …) for
  one project folder. Never reused: the high-water marks are written to
  `.universe/ids.json` on every allocation and restored at boot.
  """

  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Allocates the next worker ID."
  def next_worker, do: GenServer.call(__MODULE__, {:next, "worker"})

  @doc "Allocates the next tick number."
  def next_tick, do: GenServer.call(__MODULE__, {:next, "tick"})

  @impl true
  def init(_opts) do
    path = Path.join(Universe.Paths.universe_dir(), "ids.json")

    counters =
      with {:ok, text} <- File.read(path), {:ok, %{} = map} <- Jason.decode(text) do
        Map.merge(%{"worker" => 0, "tick" => 0}, map)
      else
        _ -> %{"worker" => 0, "tick" => 0}
      end

    {:ok, %{path: path, counters: counters}}
  end

  @impl true
  def handle_call({:next, kind}, _from, state) do
    n = state.counters[kind] + 1
    counters = Map.put(state.counters, kind, n)
    persist!(state.path, counters)
    {:reply, n, %{state | counters: counters}}
  end

  # Write-then-rename so a crash never leaves a truncated file behind.
  defp persist!(path, counters) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(counters))
    File.rename!(tmp, path)
  end
end
