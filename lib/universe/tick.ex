defmodule Universe.Tick do
  @moduledoc """
  Turns batches of directives into workers and decides when to answer.

  A `tick` call is accepted, validated and started at once, then parked: the
  caller is answered later (`GenServer.reply/2`) when a wake rule fires, so
  the server keeps handling worker exits while the model waits.

  Wake rules, checked on every status change and twice a second:
    * `settled`   - the watched IDs settled (`until: "all"`, default) or one
                    of them did (`until: "any"`); `serving` and `asking`
                    count as settled
    * `attention` - a failed or asking worker has gone unreported for 20 s
    * `timeout`   - `wait.timeout_s` passed (default 60, capped at 90)

  Watched IDs default to the IDs this tick created; with none, every live ID.
  `then` steps a watched worker starts join the watch.

  Kinds of ID: `run` snippets, `serve` services and `call`s to services.
  A queued ID starts when every `after` ID is `done` (or `serving`); if one
  ends any other way it fails without starting. A call also waits for its
  service to be serving. A crashing service restarts, at most 3 times in 60 s.

  On boot the worker table is rebuilt from the event log; IDs that were live
  when Universe stopped are recorded as `killed` ("lost: Universe restarted").
  Settled workers are compacted (code dropped) and, past `max_settled`,
  archived to a bare `{status, label}` so a long-running daemon stays bounded.
  """

  use GenServer

  alias Universe.{Digest, Directive, EventLog, Handles, Ids, Leases, Secrets, Services, Worker}

  @default_timeout_s 60
  @max_timeout_s 90
  @attention_ms 20_000
  @check_ms 500
  @default_max_running 16
  @default_max_settled 1_000
  @max_services 20
  @restart_window_ms 60_000
  @max_restarts 3
  @inline_result_chars 1_000

  @live ~w(queued running serving asking)
  @settled ~w(done failed budget killed rejected asking serving)
  @terminal ~w(done failed budget killed rejected)
  @attention ~w(failed budget asking)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one tick; returns `%{text: digest, structured: map}`."
  def submit(args) when is_map(args) do
    GenServer.call(__MODULE__, {:tick, args}, (@max_timeout_s + 15) * 1000)
  end

  @doc "Kills every live worker and call, and logs `stop_all`."
  def stop_all, do: GenServer.call(__MODULE__, :stop_all)

  @doc "Current worker table: `%{id => worker}` (archived workers excluded)."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Currently held leases: `%{id => [path]}`."
  def leases, do: GenServer.call(__MODULE__, :leases)

  @doc "In-flight call tasks: `%{task_pid => call_id}` (for the observer)."
  def call_tasks, do: GenServer.call(__MODULE__, :call_tasks)

  @doc "IDs that are queued, running, serving or asking."
  def live_ids, do: GenServer.call(__MODULE__, :live_ids)

  @doc "Idle TTL in seconds of each serving service: `%{id => ttl}`."
  def service_ttls, do: GenServer.call(__MODULE__, :service_ttls)

  @doc "Stops a worker on behalf of the garbage collector."
  def gc_kill(id, reason), do: GenServer.cast(__MODULE__, {:gc_kill, id, reason})

  @doc "Called by a worker's SDK connection; blocks until the model replies."
  def ask(id, question), do: GenServer.call(__MODULE__, {:ask, id, question}, :infinity)

  @doc "Called by a worker's SDK connection once `U.serve` registered it."
  def service_ready(id, name, fns, describe),
    do: GenServer.call(__MODULE__, {:service_ready, id, name, fns, describe})

  def max_timeout_s, do: @max_timeout_s

  ## Server

  @impl true
  def init(opts) do
    Secrets.load_into_log()

    state = %{
      workers: %{},
      archive: %{},
      labels: %{},
      services: %{},
      leases: %{},
      monitors: %{},
      tasks: %{},
      cursor: 0,
      waiters: %{},
      timer: nil,
      max_running: opt(opts, :max_running, @default_max_running),
      max_settled: opt(opts, :max_settled, @default_max_settled)
    }

    {:ok, recover(state)}
  end

  defp opt(opts, key, default),
    do: Keyword.get(opts, key, Application.get_env(:universe, key, default))

  @impl true
  def handle_call({:tick, args}, from, state) do
    args = if is_map(args["wait"]), do: args, else: Map.delete(args, "wait")
    tick = Ids.next_tick()

    since =
      if is_integer(args["since"]) and args["since"] >= 0, do: args["since"], else: state.cursor

    EventLog.append("tick_in", tick: tick, data: Map.take(args, ["directives", "wait", "since"]))

    {accepted, rejected} = Directive.validate(args["directives"], &resolve(state, &1))
    {state, new_ids, more_rejected} = apply_directives(state, tick, accepted)
    rejected = rejected ++ more_rejected ++ unknown_wait_ids(state, args["wait"])
    Enum.each(rejected, &EventLog.append("rejected", tick: tick, data: stringify(&1)))

    state = schedule(state)

    waiter = %{
      from: from,
      tick: tick,
      since: since,
      args: args,
      rejected: rejected,
      started_ms: now(),
      until: if(get_in(args, ["wait", "until"]) == "any", do: "any", else: "all"),
      watch: watch_set(state, args["wait"], new_ids),
      deadline_ms: now() + timeout_s(args["wait"]) * 1000
    }

    state = %{state | waiters: Map.put(state.waiters, make_ref(), waiter)}
    {:noreply, state |> check_waiters() |> ensure_timer()}
  end

  def handle_call(:stop_all, _from, state) do
    live = for {id, w} <- state.workers, w.status in @live, do: id
    EventLog.append("stop_all", data: %{"ids" => Enum.map(live, &"##{&1}")})
    state = Enum.reduce(live, state, &stop(&2, &1, "stopped by stop all"))
    {:reply, {:ok, length(live)}, check_waiters(state)}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, state.workers, state}
  def handle_call(:leases, _from, state), do: {:reply, state.leases, state}

  def handle_call(:call_tasks, _from, state),
    do: {:reply, Map.new(state.tasks, fn {_ref, {id, pid}} -> {pid, id} end), state}

  def handle_call(:live_ids, _from, state) do
    {:reply, for({id, w} <- state.workers, w.status in @live, into: MapSet.new(), do: id), state}
  end

  def handle_call(:service_ttls, _from, state) do
    ttls =
      for {id, %{kind: "serve", status: "serving"} = w} <- state.workers,
          into: %{},
          do: {id, w.spec.ttl_idle_s}

    {:reply, ttls, state}
  end

  def handle_call({:ask, id, question}, from, state) do
    case state.workers[id] do
      %{status: status} = w when status in ["running", "serving"] ->
        EventLog.append("ask", tick: w.tick, id: id, data: %{"question" => question})

        w = %{
          w
          | status: "asking",
            prior_status: status,
            asker: from,
            question: question,
            attention_seq: EventLog.last_seq(),
            attention_at: now()
        }

        {:noreply, put_in(state.workers[id], w) |> check_waiters()}

      _ ->
        {:reply, {:error, "worker ##{id} is not running"}, state}
    end
  end

  def handle_call({:service_ready, id, name, fns, describe}, _from, state) do
    holder = state.services[name]

    cond do
      not match?(%{status: s} when s in ["running", "asking"], state.workers[id]) ->
        {:reply, {:error, "worker ##{id} is not running"}, state}

      holder && holder != id && status_of(state, holder) in @live ->
        {:reply, {:error, "service name #{name} is taken by ##{holder}"}, state}

      true ->
        w = state.workers[id]

        EventLog.append("serve",
          tick: w.tick,
          id: id,
          data: %{"name" => name, "fns" => fns, "describe" => describe}
        )

        w = %{w | status: "serving", service: name, fns: fns, describe: describe}
        state = %{state | services: Map.put(state.services, name, id)} |> put_worker(w)
        {:reply, :ok, state |> schedule() |> check_waiters()}
    end
  end

  @impl true
  def handle_cast({:gc_kill, id, reason}, state) do
    state =
      case state.workers[id] do
        %{status: s} when s in @live -> stop(state, id, reason)
        _ -> state
      end

    {:noreply, check_waiters(state)}
  end

  @impl true
  def handle_info({:worker_exit, id, summary}, state) do
    state =
      case state.workers[id] do
        %{kind: "serve", status: s} = w when s in ["running", "serving", "asking"] ->
          maybe_restart(state, w, summary)

        _ ->
          settle(state, id, summary)
      end

    {:noreply, state |> schedule() |> check_waiters()}
  end

  def handle_info({:restart, id}, state) do
    state =
      case state.workers[id] do
        %{status: "running", kill_reason: nil} = w -> start_process(state, w)
        _ -> state
      end

    {:noreply, check_waiters(state)}
  end

  # A call task finished.
  def handle_info({ref, result}, state) when is_map_key(state.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {{id, _pid}, tasks} = Map.pop(state.tasks, ref)
    state = %{state | tasks: tasks} |> finish_call(id, result)
    {:noreply, state |> schedule() |> check_waiters()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.tasks, ref) do
    {{id, _pid}, tasks} = Map.pop(state.tasks, ref)
    w = state.workers[id]

    summary =
      if w && w.kill_reason,
        do: %{"status" => "killed", "reason" => w.kill_reason},
        else: %{"status" => "failed", "reason" => "call crashed: #{inspect(reason)}"}

    state = %{state | tasks: tasks} |> settle_with_event(id, summary)
    {:noreply, state |> schedule() |> check_waiters()}
  end

  # Workers report their exit before stopping normally, so only an abnormal
  # exit means the worker GenServer itself crashed.
  def handle_info({:DOWN, ref, :process, _pid, :normal}, state) do
    {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {id, monitors} = Map.pop(state.monitors, ref)
    state = %{state | monitors: monitors}

    state =
      case id && state.workers[id] do
        %{status: s, kind: kind} when s in ["running", "serving", "asking"] and kind != "call" ->
          state
          |> settle_with_event(id, down_summary(reason))
          |> schedule()
          |> check_waiters()

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info(:check, state) do
    {:noreply, %{state | timer: nil} |> check_waiters() |> ensure_timer()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Directives

  # Pass 1 gives every run, serve and call an ID (and holds leases) so `after`
  # can point at labels later in the batch; pass 2 resolves dependencies.
  defp apply_directives(state, tick, accepted) do
    batch_services =
      for %{op: "serve"} = d <- accepted,
          name <- [d.service | List.wrap(d[:agent] && d.agent.pool)],
          into: MapSet.new(),
          do: name

    {state, placed, rejected} =
      Enum.reduce(accepted, {state, [], []}, fn d, {st, placed, rej} ->
        case place(st, tick, d, batch_services) do
          {:placed, st, id} -> {st, placed ++ [{id, d}], rej}
          {:ok, st} -> {st, placed, rej}
          {:error, reason} -> {st, placed, rej ++ [%{label: d.label, op: d.op, reason: reason}]}
        end
      end)

    batch = Map.new(placed, fn {id, d} -> {d.label, id} end)
    # A label rejected in this batch must not fall back to an older worker
    # that happens to share it.
    gone = rejected |> Enum.map(& &1.label) |> Enum.reject(&is_nil/1) |> MapSet.new()

    dep_id = fn st, ref ->
      cond do
        Map.has_key?(batch, ref) -> batch[ref]
        MapSet.member?(gone, ref) -> nil
        true -> ok_id(resolve(st, ref))
      end
    end

    state =
      Enum.reduce(placed, state, fn {id, d}, st ->
        deps = Enum.map(d.after, &dep_id.(st, &1))

        if Enum.any?(deps, &is_nil/1) do
          missing = Enum.find(d.after, &is_nil(dep_id.(st, &1)))

          settle_with_event(st, id, %{
            "status" => "failed",
            "reason" => "dep #{missing} was rejected"
          })
        else
          queued_event(st.workers[id], deps, nil)
          put_in(st.workers[id].deps, deps)
        end
      end)

    {state, Enum.map(placed, &elem(&1, 0)), rejected}
  end

  defp place(state, tick, %{op: "run"} = d, _batch_services) do
    with :ok <- lease_free(state, d.leases) do
      id = Ids.next_worker()
      {:placed, add_worker(state, id, tick, "run", d), id}
    end
  end

  defp place(state, tick, %{op: "serve"} = d, _batch_services) do
    holder = state.services[d.service]

    live_services =
      Enum.count(state.workers, fn {_, w} -> w.kind == "serve" and w.status in @live end)

    cond do
      holder && status_of(state, holder) in @live ->
        {:error, "service #{d.service} already runs as ##{holder}; kill it first"}

      live_services >= @max_services ->
        {:error, "at most #{@max_services} live services; kill one first"}

      true ->
        with :ok <- lease_free(state, d.leases) do
          id = Ids.next_worker()
          state = add_worker(state, id, tick, "serve", d)
          {:placed, %{state | services: Map.put(state.services, d.service, id)}, id}
        end
    end
  end

  defp place(state, tick, %{op: "call"} = d, batch_services) do
    holder = state.services[d.service]

    live? =
      MapSet.member?(batch_services, d.service) or
        (holder != nil and status_of(state, holder) in @live) or
        pool_members(state, d.service) != []

    if live? do
      id = Ids.next_worker()
      {:placed, add_worker(state, id, tick, "call", d), id}
    else
      {:error, "no live service or agent pool #{d.service}; start it with serve"}
    end
  end

  defp place(state, _tick, %{op: "kill", target: target}, _) do
    case resolve(state, target) do
      {:ok, id} ->
        case status_of(state, id) do
          s when s in @live -> {:ok, stop(state, id, nil)}
          status -> {:error, "#{target} is already #{status}"}
        end

      :error ->
        {:error, "no worker #{target}"}
    end
  end

  defp place(state, _tick, %{op: "reply", target: target, text: text}, _) do
    with {:ok, id} <- resolve(state, target),
         %{status: "asking"} = w <- state.workers[id] do
      EventLog.append("reply",
        tick: w.tick,
        id: id,
        data: %{"text" => String.slice(text, 0, 2000)}
      )

      GenServer.reply(w.asker, {:ok, text})

      {:ok,
       put_worker(state, %{
         w
         | status: w.prior_status,
           asker: nil,
           question: nil,
           prior_status: nil
       })}
    else
      :error -> {:error, "no worker #{target}"}
      _ -> {:error, "#{target} is not asking"}
    end
  end

  defp lease_free(state, leases) do
    case Leases.conflict(state.leases, leases) do
      nil -> :ok
      {path, holder, _} -> {:error, "lease #{path} held by ##{holder}"}
    end
  end

  defp add_worker(state, id, tick, kind, d) do
    worker = %{
      id: id,
      label: d.label,
      tick: tick,
      kind: kind,
      status: "queued",
      spec: d,
      deps: [],
      quiet: Map.get(d, :quiet, false),
      queued_ms: now(),
      started_ms: nil,
      ended_ms: nil,
      settled_seq: nil,
      attention_seq: nil,
      attention_at: nil,
      summary: nil,
      then_ids: [],
      service: if(kind == "serve", do: d.service),
      fns: [],
      describe: nil,
      asker: nil,
      question: nil,
      prior_status: nil,
      restarts: [],
      kill_reason: nil
    }

    leases = Map.get(d, :leases, [])

    if leases != [],
      do:
        EventLog.append("lease",
          tick: tick,
          id: id,
          data: %{"action" => "hold", "paths" => leases}
        )

    %{
      state
      | workers: Map.put(state.workers, id, worker),
        labels: Map.put(state.labels, d.label, id),
        leases: if(leases == [], do: state.leases, else: Map.put(state.leases, id, leases))
    }
  end

  defp queued_event(w, deps, then_of) do
    data = %{"label" => w.label, "kind" => w.kind, "after" => Enum.map(deps, &"##{&1}")}
    data = if then_of, do: Map.put(data, "then_of", "##{then_of}"), else: data

    data =
      if w.kind == "call",
        do: Map.merge(data, %{"service" => w.spec.service, "fn" => w.spec.fn}),
        else: data

    EventLog.append("queued", tick: w.tick, id: w.id, data: data)
  end

  # Stops a live ID. `reason` (if any) ends up in its exit summary.
  defp stop(state, id, reason) do
    w = state.workers[id]
    # Marked so waits hold until it is really gone: a serving service would
    # otherwise count as settled and the kill would surface a tick later.
    state = put_worker(state, Map.merge(w, %{kill_reason: reason, stopping: true}))

    case w.status do
      "queued" ->
        settle_with_event(state, id, %{
          "status" => "killed",
          "reason" => reason || "killed before start"
        })

      _ when w.kind == "call" ->
        case Enum.find(state.tasks, fn {_ref, {tid, _}} -> tid == id end) do
          {_ref, {_, pid}} -> Process.exit(pid, :kill)
          nil -> :ok
        end

        state

      _ ->
        Worker.kill(id)
        state
    end
  end

  defp resolve(state, ref) do
    case Directive.parse_id(ref) do
      {:ok, id} ->
        if Map.has_key?(state.workers, id) or Map.has_key?(state.archive, id),
          do: {:ok, id},
          else: :error

      :error ->
        Map.fetch(state.labels, ref)
    end
  end

  defp ok_id({:ok, id}), do: id
  defp ok_id(:error), do: nil

  defp status_of(state, id) do
    case state.workers[id] do
      %{status: s} -> s
      nil -> get_in(state.archive, [id, :status])
    end
  end

  defp put_worker(state, w), do: %{state | workers: Map.put(state.workers, w.id, w)}

  ## Scheduling

  defp schedule(state) do
    queued =
      state.workers
      |> Map.values()
      |> Enum.filter(&(&1.status == "queued"))
      |> Enum.sort_by(& &1.id)

    {state, changed?} =
      Enum.reduce(queued, {state, false}, fn w, {st, changed?} ->
        dep_states = Enum.map(w.deps, &{&1, status_of(st, &1)})

        case readiness(st, w, dep_states) do
          :ready ->
            {start(st, st.workers[w.id]), true}

          {:fail, reason} ->
            {settle_with_event(st, w.id, %{"status" => "failed", "reason" => reason}), true}

          :wait ->
            {st, changed?}
        end
      end)

    # A failure can doom further dependents; a then step may now be queued.
    if changed?, do: schedule(state), else: state
  end

  defp readiness(state, w, dep_states) do
    cond do
      bad = Enum.find(dep_states, fn {_, s} -> s in @terminal and s != "done" end) ->
        {dep, s} = bad
        {:fail, "dep ##{dep} #{s}"}

      not Enum.all?(dep_states, fn {_, s} -> s in ["done", "serving"] end) ->
        :wait

      w.kind == "call" and Map.has_key?(state.services, w.spec.service) ->
        sid = state.services[w.spec.service]

        case status_of(state, sid) do
          "serving" -> :ready
          s when s in @terminal -> {:fail, "service #{w.spec.service} is #{s}"}
          nil -> {:fail, "no service #{w.spec.service}"}
          _ -> :wait
        end

      w.kind == "call" ->
        case pool_members(state, w.spec.service) do
          [] -> {:fail, "no service or agent pool #{w.spec.service}"}
          members -> if free_member(state, members), do: :ready, else: :wait
        end

      w.kind == "run" ->
        if running_count(state) < state.max_running, do: :ready, else: :wait

      true ->
        :ready
    end
  end

  defp running_count(state),
    do: Enum.count(state.workers, fn {_, w} -> w.kind == "run" and w.status == "running" end)

  # Live agents of a pool (queued and starting ones too, so a call can wait).
  defp pool_members(state, pool) do
    for {_, %{kind: "serve", status: s, spec: %{agent: %{pool: ^pool}}} = w} <- state.workers,
        s in @live,
        do: w
  end

  # A serving pool member with no call running on it, lowest ID first.
  defp free_member(state, members) do
    busy =
      for {_, %{kind: "call", status: "running"} = c} <- state.workers,
          into: MapSet.new(),
          do: c.spec.service

    members
    |> Enum.filter(&(&1.status == "serving" and not MapSet.member?(busy, &1.service)))
    |> Enum.min_by(& &1.id, fn -> nil end)
  end

  defp start(state, %{kind: "call"} = w) do
    w =
      if Map.has_key?(state.services, w.spec.service) do
        w
      else
        # A pool call: hand it to a free member.
        member = free_member(state, pool_members(state, w.spec.service))
        %{w | spec: Map.merge(w.spec, %{pool: w.spec.service, service: member.service})}
      end

    %{service: service, fn: fun, args: args, timeout_s: timeout} = w.spec

    EventLog.append("call",
      tick: w.tick,
      id: w.id,
      data:
        %{"service" => service, "fn" => fun, "args" => clip_json(args, 500), "via" => "tick"}
        |> then(&if(w.spec[:pool], do: Map.put(&1, "pool", w.spec.pool), else: &1))
        |> then(&if(prompt = agent_prompt(args), do: Map.put(&1, "prompt", prompt), else: &1))
    )

    task =
      Task.Supervisor.async_nolink(Universe.TaskSup, fn ->
        Services.invoke(service, fun, args, timeout * 1000)
      end)

    state = %{state | tasks: Map.put(state.tasks, task.ref, {w.id, task.pid})}
    put_worker(state, %{w | status: "running", started_ms: now()})
  end

  defp start(state, w) do
    if w.kind == "serve", do: Secrets.load_into_log()
    w = %{w | status: "running", started_ms: now()}
    start_process(put_worker(state, w), w)
  end

  defp start_process(state, w) do
    d = w.spec

    spec = %{
      id: w.id,
      label: w.label,
      tick: w.tick,
      kind: w.kind,
      lang: d.lang,
      code: d.code,
      agent: Map.get(d, :agent),
      budget: d.budget,
      leases: d.leases,
      network: Map.get(d, :network, []),
      service: Map.get(d, :service),
      notify: self()
    }

    case Worker.start(spec) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        %{state | monitors: Map.put(state.monitors, ref, w.id)}

      {:error, {:already_started, _}} ->
        # The previous process is still unregistering; try again shortly.
        Process.send_after(self(), {:restart, w.id}, 100)
        state

      {:error, reason} ->
        settle_with_event(state, w.id, %{
          "status" => "failed",
          "reason" => "could not start: #{inspect(reason)}"
        })
    end
  end

  defp maybe_restart(state, w, summary) do
    recent = Enum.filter(w.restarts, &(now() - &1 < @restart_window_ms))

    cond do
      w.kill_reason != nil or summary["status"] in ["killed", "budget", "done"] ->
        settle(state, w.id, summary)

      length(recent) >= @max_restarts ->
        reason = "crashed #{@max_restarts + 1} times in #{div(@restart_window_ms, 1000)}s"

        settle_with_event(
          state,
          w.id,
          Map.put(summary, "reason", reason) |> Map.put("status", "failed")
        )

      true ->
        if w.asker, do: GenServer.reply(w.asker, {:error, "worker restarted"})
        attempt = length(recent) + 1

        EventLog.append("restart",
          tick: w.tick,
          id: w.id,
          data: %{
            "attempt" => attempt,
            "code" => summary["code"],
            "last_err" => summary["last_err"]
          }
        )

        Process.send_after(self(), {:restart, w.id}, 200)

        put_worker(state, %{
          w
          | status: "running",
            restarts: [now() | recent],
            asker: nil,
            question: nil,
            service: w.spec.service
        })
    end
  end

  defp finish_call(state, id, {:ok, value}) do
    text = clip_json(value, nil)

    summary =
      if String.length(text) <= @inline_result_chars do
        %{"status" => "done", "result" => value, "result_text" => text}
      else
        case Handles.put(id, "result", value) do
          {:ok, handle, meta} ->
            w = state.workers[id]

            EventLog.append("put",
              tick: w.tick,
              id: id,
              data: %{"handle" => handle, "kind" => meta["kind"], "summary" => meta["summary"]}
            )

            %{"status" => "done", "handle" => handle, "handle_summary" => meta["summary"]}

          {:error, reason} ->
            %{"status" => "failed", "reason" => "result could not be stored: #{reason}"}
        end
      end

    settle_with_event(
      state,
      id,
      Map.put(summary, "wall_ms", now() - state.workers[id].started_ms)
    )
  end

  defp finish_call(state, id, {:error, reason}) do
    settle_with_event(state, id, %{
      "status" => "failed",
      "reason" => to_string(reason),
      "wall_ms" => now() - state.workers[id].started_ms
    })
  end

  # Records the end of an ID whose exit event is already logged.
  defp settle(state, id, summary) do
    case state.workers[id] do
      %{status: status} = w when status in @live ->
        summary =
          if (summary["status"] == "killed" and w.kill_reason) && !summary["reason"],
            do: Map.put(summary, "reason", w.kill_reason),
            else: summary

        attention? = summary["status"] in @attention

        w = %{
          w
          | status: summary["status"],
            ended_ms: now(),
            summary: summary,
            settled_seq: EventLog.last_seq(),
            attention_seq: if(attention?, do: EventLog.last_seq(), else: w.attention_seq),
            attention_at: if(attention?, do: now(), else: w.attention_at)
        }

        if w.asker, do: GenServer.reply(w.asker, {:error, "worker ended"})
        state = state |> put_worker(w) |> release_leases(id)
        state = if w.status == "done" and w.spec.then != [], do: start_then(state, w), else: state

        state
        |> compact(id)
        |> prune()

      _ ->
        state
    end
  end

  # For endings no worker process logged (never started, crashed, calls).
  defp settle_with_event(state, id, summary) do
    w = state.workers[id]
    EventLog.append("exit", tick: w.tick, id: id, data: summary)
    settle(state, id, summary)
  end

  defp release_leases(state, id) do
    case Map.pop(state.leases, id) do
      {nil, _} ->
        state

      {paths, leases} ->
        EventLog.append("lease",
          tick: state.workers[id].tick,
          id: id,
          data: %{"action" => "release", "paths" => paths}
        )

        %{state | leases: leases}
    end
  end

  defp start_then(state, parent) do
    {state, ids} =
      Enum.reduce(parent.spec.then, {state, []}, fn d, {st, ids} ->
        id = Ids.next_worker()

        case Leases.conflict(st.leases, d.leases) do
          nil ->
            st = add_worker(st, id, parent.tick, "run", d)
            queued_event(st.workers[id], [], parent.id)
            {st, ids ++ [id]}

          {path, holder, _} ->
            st = add_worker(st, id, parent.tick, "run", %{d | leases: []})

            st =
              settle_with_event(st, id, %{
                "status" => "failed",
                "reason" => "lease #{path} held by ##{holder}"
              })

            {st, ids ++ [id]}
        end
      end)

    state = put_in(state.workers[parent.id].then_ids, ids)

    # Waiters watching the parent now watch its then steps too.
    waiters =
      Map.new(state.waiters, fn {ref, w} ->
        if MapSet.member?(w.watch, parent.id),
          do: {ref, %{w | watch: MapSet.union(w.watch, MapSet.new(ids))}},
          else: {ref, w}
      end)

    %{state | waiters: waiters}
  end

  ## Bounded memory

  # Settled workers keep only what digests and dependents need.
  defp compact(state, id) do
    case state.workers[id] do
      %{status: s} = w when s in @terminal ->
        spec =
          w.spec
          |> Map.put(:code, nil)
          |> Map.put(:args, nil)
          |> Map.put(:then, Enum.map(w.spec.then, &%{label: &1.label}))

        put_worker(state, %{w | spec: spec})

      _ ->
        state
    end
  end

  defp prune(state) do
    settled = for {id, w} <- state.workers, w.status in @terminal, do: id
    excess = length(settled) - state.max_settled

    if excess > 0 do
      pinned =
        MapSet.new(
          Enum.flat_map(state.workers, fn {_, w} -> if w.status in @live, do: w.deps, else: [] end) ++
            Enum.flat_map(state.waiters, fn {_, w} -> MapSet.to_list(w.watch) end)
        )

      drop =
        settled |> Enum.sort() |> Enum.reject(&MapSet.member?(pinned, &1)) |> Enum.take(excess)

      archive =
        Enum.reduce(drop, state.archive, fn id, acc ->
          Map.put(acc, id, %{status: state.workers[id].status, label: state.workers[id].label})
        end)

      %{state | workers: Map.drop(state.workers, drop), archive: archive}
    else
      state
    end
  end

  ## Recovery

  # Rebuilds the worker table from the log; live-at-shutdown IDs become killed.
  defp recover(state) do
    events = EventLog.since(0)

    cursor =
      events
      |> Enum.filter(&(&1["type"] == "tick_out"))
      |> List.last()
      |> case do
        nil -> 0
        e -> get_in(e, ["data", "structured", "cursor"]) || 0
      end

    records =
      Enum.reduce(events, %{}, fn e, acc ->
        if id = e["id"], do: Map.update(acc, id, [e], &[e | &1]), else: acc
      end)

    state =
      records
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(%{state | cursor: cursor}, fn {id, evs}, st ->
        recover_worker(st, id, Enum.reverse(evs))
      end)

    prune(state)
  end

  defp recover_worker(state, id, events) do
    first = Enum.find(events, &(&1["type"] in ["queued", "spawn"]))

    if first do
      spawn = Enum.find(events, &(&1["type"] == "spawn"))
      exit = events |> Enum.filter(&(&1["type"] == "exit")) |> List.last()
      serve = events |> Enum.filter(&(&1["type"] == "serve")) |> List.last()
      call = Enum.find(events, &(&1["type"] == "call"))
      label = first["data"]["label"]
      kind = first["data"]["kind"] || (spawn && spawn["data"]["kind"]) || "run"

      summary =
        case exit do
          nil ->
            data = %{"status" => "killed", "reason" => "lost: Universe restarted"}
            EventLog.append("exit", tick: first["tick"], id: id, data: data)
            data

          e ->
            e["data"]
        end

      budget = (spawn && spawn["data"]["budget"]) || %{}

      w = %{
        id: id,
        label: label,
        tick: first["tick"],
        kind: kind,
        status: summary["status"],
        spec: %{
          code: nil,
          args: nil,
          then: [],
          leases: [],
          lang: spawn && spawn["data"]["lang"],
          budget: %{wall_s: budget["wall_s"], out_kb: budget["out_kb"], mem_mb: budget["mem_mb"]},
          ttl_idle_s: nil,
          # A call keeps its target, so views can still say what it called.
          service: (serve && serve["data"]["name"]) || (call && call["data"]["service"]),
          fn: call && call["data"]["fn"],
          agent: nil
        },
        deps: [],
        quiet: false,
        queued_ms: nil,
        started_ms: nil,
        ended_ms: now(),
        settled_seq: exit && exit["seq"],
        attention_seq: nil,
        attention_at: nil,
        summary: summary,
        then_ids: [],
        service: serve && serve["data"]["name"],
        fns: (serve && serve["data"]["fns"]) || [],
        describe: serve && serve["data"]["describe"],
        asker: nil,
        question: nil,
        prior_status: nil,
        restarts: [],
        kill_reason: nil
      }

      state = put_worker(state, w)
      state = if label, do: %{state | labels: Map.put(state.labels, label, id)}, else: state
      if w.service, do: %{state | services: Map.put(state.services, w.service, id)}, else: state
    else
      state
    end
  end

  ## Waiting

  defp watch_set(state, wait, new_ids) do
    refs = if is_map(wait) and is_list(wait["ids"]), do: wait["ids"], else: nil

    cond do
      refs ->
        refs
        |> Enum.map(&ok_id(resolve(state, to_string(&1))))
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&Map.has_key?(state.workers, &1))
        |> MapSet.new()

      new_ids != [] ->
        MapSet.new(new_ids)

      true ->
        for {id, w} <- state.workers, w.status not in @settled, into: MapSet.new(), do: id
    end
  end

  # A typo'd wait id would otherwise shrink the watch silently.
  defp unknown_wait_ids(state, %{"ids" => refs}) when is_list(refs) do
    for ref <- refs,
        resolve(state, to_string(ref)) == :error,
        do: %{label: to_string(ref), op: "wait", reason: "wait: no worker #{ref}"}
  end

  defp unknown_wait_ids(_state, _wait), do: []

  defp timeout_s(%{"timeout_s" => t}) when is_number(t),
    do: t |> max(0) |> min(@max_timeout_s) |> trunc()

  defp timeout_s(_), do: @default_timeout_s

  defp check_waiters(state) do
    Enum.reduce(state.waiters, state, fn {ref, waiter}, st ->
      case wake_rule(st, waiter) do
        nil -> st
        rule -> reply(%{st | waiters: Map.delete(st.waiters, ref)}, waiter, rule)
      end
    end)
  end

  defp wait_status(state, id) do
    case state.workers[id] do
      %{stopping: true, status: s} when s in @live -> "stopping"
      _ -> status_of(state, id)
    end
  end

  defp wake_rule(state, waiter) do
    statuses = Enum.map(waiter.watch, &wait_status(state, &1))
    t = now()

    cond do
      statuses == [] -> "now"
      waiter.until == "all" and Enum.all?(statuses, &(&1 in @settled)) -> "settled"
      waiter.until == "any" and Enum.any?(statuses, &(&1 in @settled)) -> "settled"
      attention?(state, waiter, t) -> "attention"
      t >= waiter.deadline_ms -> "timeout"
      true -> nil
    end
  end

  defp attention?(state, waiter, t) do
    Enum.any?(state.workers, fn {_, w} ->
      w.status in @attention and w.attention_seq != nil and w.attention_seq > waiter.since and
        t - w.attention_at >= attention_ms()
    end)
  end

  defp attention_ms, do: Application.get_env(:universe, :attention_ms, @attention_ms)

  defp ensure_timer(%{waiters: waiters, timer: nil} = state) when map_size(waiters) > 0,
    do: %{state | timer: Process.send_after(self(), :check, @check_ms)}

  defp ensure_timer(state), do: state

  ## Answer

  defp reply(state, waiter, rule) do
    events = EventLog.since(waiter.since)

    changed =
      events
      |> Enum.map(& &1["id"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.filter(&Map.has_key?(state.workers, &1))

    by_id = Enum.group_by(events, & &1["id"])

    rows =
      Enum.map(changed, &row(state.workers[&1], Map.get(by_id, &1, []))) ++
        Enum.map(
          waiter.rejected,
          &%{id: nil, label: &1.label || &1.op || "?", status: "rejected", detail: &1.reason}
        )

    cursor = EventLog.last_seq()

    text =
      Digest.build(%{
        tick: waiter.tick,
        rows: rows,
        running: Enum.count(state.workers, fn {_, w} -> w.status == "running" end),
        queued: Enum.count(state.workers, fn {_, w} -> w.status == "queued" end),
        cursor: cursor,
        wake: rule
      })

    structured = %{
      "tick" => waiter.tick,
      "cursor" => cursor,
      "wake" => rule,
      "ids" =>
        Map.new(changed, fn id ->
          w = state.workers[id]
          {"##{id}", %{"status" => w.status, "label" => w.label, "kind" => w.kind}}
        end),
      "rejected" => Enum.map(waiter.rejected, &stringify/1)
    }

    EventLog.append("tick_out",
      tick: waiter.tick,
      data: %{
        "text" => text,
        "structured" => structured,
        "wake" => rule,
        "wait_ms" => now() - waiter.started_ms,
        "tokens_in_est" => waiter.args |> Jason.encode!() |> Digest.estimate_tokens(),
        "tokens_out_est" => Digest.estimate_tokens(text)
      }
    )

    GenServer.reply(waiter.from, %{text: text, structured: structured})
    # This waiter no longer pins its watched IDs.
    prune(%{state | cursor: max(state.cursor, cursor)})
  end

  defp row(w, recent) do
    %{id: w.id, label: w.label, status: w.status, quiet: w.quiet, detail: detail(w, recent)}
  end

  defp detail(%{status: "queued"} = w, _recent) do
    cond do
      w.deps != [] -> "after " <> Enum.map_join(w.deps, ", ", &"##{&1}")
      w.kind == "call" -> "waiting for #{w.spec.service}"
      true -> "waiting for a slot"
    end
  end

  defp detail(%{status: "asking"} = w, _recent), do: "asks: #{w.question}"

  defp detail(%{status: "serving", spec: %{agent: %{} = agent}} = w, recent) do
    restarted = Enum.any?(recent, &(&1["type"] == "restart"))

    progress =
      case EventLog.for_id_since(w.id, 0) |> Enum.filter(&(&1["type"] == "progress")) do
        [] -> "idle"
        events -> List.last(events)["data"]["text"]
      end

    join([
      "agent #{w.service}",
      agent.pool && "pool #{agent.pool}",
      agent.model,
      progress,
      restarted && "restarted"
    ])
  end

  defp detail(%{status: "serving"} = w, recent) do
    restarted = Enum.any?(recent, &(&1["type"] == "restart"))

    join([
      "serving #{w.service}",
      w.fns != [] && "fns: #{Enum.join(w.fns, ", ")}",
      w.describe != "" && w.describe,
      restarted && "restarted"
    ])
  end

  defp detail(%{status: "running", kind: "call"} = w, _recent) do
    "calling #{w.spec.service}.#{w.spec.fn} · #{Digest.duration(now() - w.started_ms)}"
  end

  defp detail(%{status: "running"} = w, recent) do
    elapsed = Digest.duration(now() - (w.started_ms || now()))

    restart =
      case Enum.filter(recent, &(&1["type"] == "restart")) |> List.last() do
        nil -> nil
        e -> "restarting (#{e["data"]["attempt"]}/#{@max_restarts}) · #{e["data"]["last_err"]}"
      end

    case restart || live_line(recent) do
      nil -> elapsed
      line -> "#{elapsed} · last: #{line}"
    end
  end

  defp detail(%{kind: "call"} = w, _recent) do
    s = w.summary || %{}

    case {w.status, s["handle"]} do
      {"done", handle} when is_binary(handle) -> "→ #{handle} (#{s["handle_summary"]})"
      {"done", _} -> join([Digest.duration(s["wall_ms"]), "→ #{s["result_text"]}"])
      _ -> join([s["reason"], Digest.duration(s["wall_ms"])])
    end
  end

  defp detail(w, recent) do
    s = w.summary || %{}
    took = Digest.duration(s["wall_ms"])
    last = s["last_out"]
    err = s["last_err"] || last

    handles =
      for(e <- recent, e["type"] == "put", do: "#{e["data"]["handle"]} (#{e["data"]["summary"]})")
      |> Enum.take(3)

    base =
      case w.status do
        "done" when handles != [] -> join([took, "→ " <> Enum.join(handles, ", ")])
        "done" -> join([took, last])
        "failed" -> join([s["reason"] || "exit #{s["code"]}", err])
        "budget" -> join([s["reason"] || "budget hit", err])
        "killed" -> join([s["reason"] || "killed after #{took}", last])
        other -> join([other, last])
      end

    then =
      cond do
        w.then_ids != [] ->
          "then " <> Enum.map_join(w.then_ids, ", ", &"##{&1}")

        w.spec.then != [] and w.status != "done" ->
          "then skipped: " <> Enum.map_join(w.spec.then, ", ", & &1.label)

        true ->
          nil
      end

    join([base, then])
  end

  # Progress beats raw output; both only from events since the cursor.
  defp live_line(recent) do
    progress = recent |> Enum.filter(&(&1["type"] == "progress")) |> List.last()

    if progress do
      progress["data"]["text"]
    else
      recent
      |> Enum.filter(&(&1["type"] in ["stdout", "stderr"] and is_binary(&1["data"]["text"])))
      |> List.last()
      |> case do
        nil ->
          nil

        event ->
          event["data"]["text"]
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> List.last()
      end
    end
  end

  defp join(parts), do: parts |> Enum.reject(&(&1 in [nil, false, ""])) |> Enum.join(" · ")

  defp clip_json(value, nil), do: Jason.encode!(value)

  defp clip_json(value, max) do
    text = Jason.encode!(value)
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  # An agent task's prompt, kept whole (to 4000 chars) for the observer.
  defp agent_prompt(%{"prompt" => p}) when is_binary(p), do: String.slice(p, 0, 4000)
  defp agent_prompt(_), do: nil

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp now, do: System.monotonic_time(:millisecond)

  # A worker stopped by its supervisor (Universe shutting down) was killed,
  # not crashed; anything else is a crash.
  defp down_summary(reason) when reason == :shutdown or elem(reason, 0) == :shutdown,
    do: %{"status" => "killed", "reason" => "Universe shut down"}

  defp down_summary(reason),
    do: %{"status" => "failed", "reason" => "worker crashed: #{inspect(reason)}"}
end
