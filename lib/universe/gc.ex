defmodule Universe.GC do
  @moduledoc """
  Housekeeping that keeps a long-running daemon bounded.

    * memory budgets: one `ps` per second for all workers; a process group
      over its `mem_mb` is killed with status `budget`
    * idle services: a service with no calls for `ttl_idle_s` is stopped
    * run directories older than 7 days (of settled workers) are deleted

  Every stop is a `gc` event, so the digest and the observer show it.
  """

  use GenServer

  alias Universe.{EventLog, Paths, Services, Tick, Worker}

  @mem_table :universe_mem_watch
  @mem_ms 1_000
  @sweep_ms 15_000
  @run_dir_days 7

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Registers a worker's process group for memory checks."
  def watch_memory(id, pgid, mem_mb), do: :ets.insert(@mem_table, {id, pgid, mem_mb * 1024})

  # Workers call this from terminate/2. On shutdown GC (and its table) may
  # already be gone, which must not turn a clean stop into a crash.
  def unwatch_memory(id) do
    :ets.delete(@mem_table, id)
  rescue
    ArgumentError -> true
  end

  @doc "Runs the idle/run-dir sweep now (tests, and the observer)."
  def sweep_now, do: GenServer.call(__MODULE__, :sweep)

  @impl true
  def init(_opts) do
    :ets.new(@mem_table, [:set, :public, :named_table])
    Process.send_after(self(), :mem, @mem_ms)
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, sweep(), state}

  @impl true
  def handle_info(:mem, state) do
    check_memory()
    Process.send_after(self(), :mem, @mem_ms)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  defp check_memory do
    watched = :ets.tab2list(@mem_table)

    if watched != [] do
      case System.cmd("ps", ["-axo", "pgid=,rss="], stderr_to_stdout: true) do
        {out, 0} ->
          rss_by_group =
            for line <- String.split(out, "\n", trim: true),
                [g, r] <- [String.split(String.trim(line))],
                {pgid, ""} <- [Integer.parse(g)],
                {rss, ""} <- [Integer.parse(r)],
                reduce: %{} do
              acc -> Map.update(acc, pgid, rss, &(&1 + rss))
            end

          for {id, pgid, limit_kb} <- watched, Map.get(rss_by_group, pgid, 0) > limit_kb do
            Worker.kill(id, :mem)
          end

        _ ->
          :ok
      end
    end
  end

  defp sweep do
    %{idle: reap_idle_services(), run_dirs: prune_run_dirs()}
  end

  defp reap_idle_services do
    now = System.monotonic_time(:millisecond)
    ttls = Tick.service_ttls()

    for %{name: name, id: id, last_call_ms: last} <- Services.list(),
        ttl = Map.get(ttls, id),
        ttl != nil and now - last >= ttl * 1000 do
      EventLog.append("gc",
        id: id,
        data: %{"action" => "stop_idle", "service" => name, "idle_s" => ttl}
      )

      Tick.gc_kill(id, "idle #{ttl}s, stopped by gc")
      id
    end
  end

  defp prune_run_dirs do
    cutoff = System.os_time(:second) - @run_dir_days * 86_400
    live = Tick.live_ids()

    case File.ls(Paths.runs_dir()) do
      {:ok, entries} ->
        for entry <- entries,
            {id, ""} <- [Integer.parse(entry)],
            not MapSet.member?(live, id),
            dir = Path.join(Paths.runs_dir(), entry),
            {:ok, %File.Stat{mtime: mtime}} <- [File.stat(dir, time: :posix)],
            mtime < cutoff do
          File.rm_rf!(dir)
          EventLog.append("gc", id: id, data: %{"action" => "prune_run_dir"})
          id
        end

      {:error, _} ->
        []
    end
  end
end
