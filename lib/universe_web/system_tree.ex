defmodule UniverseWeb.SystemTree do
  @moduledoc """
  The live process tree of the daemon, labelled with what each part does.

  Walks `Supervisor.which_children/1` from `Universe.Supervisor`. Each node
  says what it is (supervisor and strategy, dynamic supervisor, task
  supervisor, GenServer, task, registry), what it is for, and who it talks
  to. Universe's own processes get their meaning attached: a worker's ID,
  label and status, the worker an SDK connection belongs to, the call a task
  is running. Under each worker hangs its OS process tree (launcher, sandbox,
  code), from `ps`.

  Supervisors from libraries (Telemetry, the endpoint, the MCP server,
  PubSub) are walked only when listed in `expanded`, and at most
  `@max_children` children are shown per node. No tracing: everything here
  comes from `Process.info/2`, `:sys.get_state/2` and `ps`.
  """

  alias Universe.Tick

  @root Universe.Supervisor
  @max_children 60
  @max_depth 8
  @state_timeout 150

  # Supervisors whose children are always shown.
  @own [
    Universe.Supervisor,
    Universe.Runtime,
    Universe.WorkerSup,
    Universe.SDK.ConnSup,
    Universe.TaskSup
  ]

  @roles %{
    Universe.Supervisor =>
      {"The application's root", "starts everything below in order; one_for_one"},
    Universe.Runtime =>
      {"Tick and its workers",
       "rest_for_one: a Tick crash restarts WorkerSup too, so no worker outlives its tracker"},
    Universe.WorkerSup =>
      {"One child per worker ID", "started by Tick · each child owns one OS process group"},
    Universe.SDK.ConnSup =>
      {"One child per SDK connection", "started by the Listener's acceptor"},
    Universe.TaskSup =>
      {"One task per call directive", "started by Tick · each calls Services.invoke"},
    Universe.Tick =>
      {"The kernel", "← MCP ticks · → WorkerSup, TaskSup, EventLog · ← worker exits, asks"},
    Universe.Services =>
      {"Live services and SDK tokens", "← Conns register · ← calls look up and invoke"},
    Universe.EventLog =>
      {"Append-only event log", "← everyone appends · → JSONL file, ETS, PubSub → pages, Tick"},
    Universe.Ids => {"Worker and tick numbers", "← Tick"},
    Universe.Lock => {"One daemon per folder", "holds .universe/daemon.pid"},
    Universe.GC =>
      {"Housekeeping",
       "→ Tick: stop idle services · → Workers: kill over memory budget · prunes run dirs"},
    Universe.SDK.Listener => {"The SDK Unix socket", "its acceptor starts a Conn per connection"},
    Universe.MCP.Server =>
      {"The MCP server (Anubis)", "← Claude Code over HTTP · → Universe.API → Tick"},
    UniverseWeb.Endpoint => {"Web server (Bandit)", "/mcp, /hooks and the observer pages"},
    UniverseWeb.Telemetry => {"Telemetry pollers", "metrics for LiveDashboard"},
    Phoenix.PubSub => {"Broadcasts", "EventLog → LiveViews"},
    Phoenix.PubSub.Supervisor => {"Broadcasts (PubSub)", "EventLog → LiveViews and Tick waiters"},
    Registry => {"Worker ID → pid", "used to find a worker's GenServer"},
    Universe.Worker =>
      {"One worker", "← Tick starts it · ↔ launcher over a port · → EventLog · → Tick on exit"},
    Universe.SDK.Conn =>
      {"One SDK connection", "↔ worker code over the socket · → EventLog, Services, Tick"},
    Task.Supervised => {"A call in flight", "→ Services.invoke → the service's Conn"}
  }

  @type node_t :: %{
          key: String.t(),
          pid: pid() | nil,
          name: String.t(),
          kind: atom(),
          strategy: atom() | nil,
          role: String.t() | nil,
          talks: String.t() | nil,
          detail: String.t() | nil,
          status: String.t() | nil,
          queue: non_neg_integer() | nil,
          memory: non_neg_integer() | nil,
          reductions: non_neg_integer() | nil,
          children: [map()],
          hidden: non_neg_integer(),
          expandable: boolean(),
          os: [map()]
        }

  @doc """
  The tree as nested maps, plus totals. `expanded` is a set of node keys
  whose library supervisors should be walked too.
  """
  def snapshot(expanded \\ MapSet.new()) do
    ctx = context()

    root =
      case Process.whereis(@root) do
        nil -> nil
        pid -> walk({@root, pid, :supervisor, [Supervisor]}, ctx, expanded, 0)
      end

    %{root: root, totals: totals(root)}
  end

  ## Walk

  defp walk({id, pid, type, modules}, ctx, expanded, depth) when is_pid(pid) do
    module = main_module(id, pid, modules)
    name = display_name(id, pid, module)
    key = key(id, pid)
    kind = kind(type, module, pid)
    {role, talks} = Map.get(@roles, role_key(id, module), {nil, nil})
    info = Process.info(pid, [:message_queue_len, :memory, :reductions])

    base = %{
      key: key,
      pid: pid,
      name: name,
      kind: kind,
      strategy: if(type == :supervisor, do: strategy(pid)),
      role: role,
      talks: talks,
      detail: nil,
      status: nil,
      queue: info && info[:message_queue_len],
      memory: info && info[:memory],
      reductions: info && info[:reductions],
      children: [],
      hidden: 0,
      expandable: false,
      os: []
    }

    base = enrich(base, module, pid, ctx)

    cond do
      type != :supervisor or depth >= @max_depth ->
        base

      own?(id) or MapSet.member?(expanded, key) ->
        kids = children(pid)
        shown = Enum.take(kids, @max_children)

        %{
          base
          | children:
              Enum.map(shown, &walk(&1, ctx, expanded, depth + 1)) |> Enum.reject(&is_nil/1),
            hidden: length(kids) - length(shown),
            expandable: not own?(id)
        }

      true ->
        %{base | expandable: true, hidden: length(children(pid))}
    end
  end

  # Restarting or not started children have no pid.
  defp walk({id, _not_pid, _type, modules}, _ctx, _expanded, _depth) do
    %{
      key: "down-#{inspect(id)}",
      pid: nil,
      name: inspect(id),
      kind: :down,
      strategy: nil,
      role: "not running",
      talks: nil,
      detail: inspect(modules),
      status: "down",
      queue: nil,
      memory: nil,
      reductions: nil,
      children: [],
      hidden: 0,
      expandable: false,
      os: []
    }
  end

  # which_children lists a supervisor's children newest first; show them in
  # start order.
  defp children(pid) do
    pid |> Supervisor.which_children() |> Enum.reverse()
  catch
    :exit, _ -> []
  end

  ## Universe meaning

  defp enrich(node, Universe.Worker, pid, ctx) do
    with [id | _] <- Registry.keys(Universe.Registry, pid),
         w when is_map(w) <- ctx.workers[id] do
      state = get_state(pid)
      launcher = launcher_pid(state)

      %{
        node
        | name: "##{id} #{w.label}",
          detail: worker_detail(w),
          status: w.status,
          os: if(launcher, do: os_tree(launcher, ctx.ps), else: [])
      }
    else
      _ -> node
    end
  end

  defp enrich(node, Universe.SDK.Conn, pid, ctx) do
    case get_state(pid) do
      %{worker: id} = state when is_integer(id) ->
        label = (ctx.workers[id] && ctx.workers[id].label) || "?"
        serving = if state[:service], do: " · serving #{state.service}", else: ""
        %{node | name: "Conn of ##{id} #{label}", detail: "authenticated#{serving}"}

      %{worker: nil} ->
        %{node | name: "Conn (not authenticated yet)"}

      _ ->
        node
    end
  end

  defp enrich(node, Task.Supervised, pid, ctx) do
    case ctx.tasks[pid] do
      nil ->
        node

      id ->
        w = ctx.workers[id]
        target = w && "#{w.spec[:service]}.#{w.spec[:fn]}"
        %{node | name: "Task for call ##{id}", detail: target && "→ #{target}"}
    end
  end

  defp enrich(node, _module, _pid, _ctx), do: node

  defp worker_detail(w) do
    kind =
      cond do
        match?(%{agent: %{}}, w.spec) -> "agent (#{w.spec.agent.model || "default model"})"
        w.kind == "serve" -> "service #{w.service || w.spec[:service]}"
        true -> "#{w.kind} · #{w.spec[:lang]}"
      end

    kind
  end

  defp launcher_pid(%{port: port}) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp launcher_pid(_), do: nil

  # The launcher and its descendants, from one `ps` snapshot.
  defp os_tree(pid, ps) do
    case ps.by_pid[pid] do
      nil -> []
      p -> [os_node(p, ps, 0)]
    end
  end

  defp os_node(p, ps, depth) do
    kids = if depth < 6, do: Map.get(ps.children, p.pid, []), else: []

    %{
      pid: p.pid,
      rss_kb: p.rss,
      command: p.command,
      children:
        kids
        |> Enum.map(&ps.by_pid[&1])
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&os_node(&1, ps, depth + 1))
    }
  end

  ## Context gathered once per snapshot

  defp context do
    workers =
      try do
        Tick.snapshot()
      catch
        :exit, _ -> %{}
      end

    tasks =
      try do
        Tick.call_tasks()
      catch
        :exit, _ -> %{}
      end

    ps =
      if Enum.any?(workers, fn {_, w} -> w.status in ~w(running serving asking) end),
        do: ps(),
        else: empty_ps()

    %{workers: workers, tasks: tasks, ps: ps}
  end

  defp empty_ps, do: %{by_pid: %{}, children: %{}}

  @doc false
  def ps do
    root = Universe.Paths.project_root()
    roots = Enum.uniq([root, Universe.Isolation.realpath(root)])

    # -ww: never truncate the command column.
    case System.cmd("ps", ["-axww", "-o", "pid=,ppid=,rss=,args="], stderr_to_stdout: true) do
      {out, 0} ->
        procs =
          for line <- String.split(out, "\n", trim: true),
              [pid, ppid, rss | args] <- [String.split(String.trim(line), ~r/\s+/, parts: 4)],
              {pid, ""} <- [Integer.parse(pid)],
              {ppid, ""} <- [Integer.parse(ppid)],
              do: %{
                pid: pid,
                ppid: ppid,
                rss: parse_int(rss),
                command: short_command(Enum.join(args, " "), roots)
              }

        %{
          by_pid: Map.new(procs, &{&1.pid, &1}),
          children:
            procs
            |> Enum.group_by(& &1.ppid, & &1.pid)
            |> Map.new(fn {k, v} -> {k, Enum.sort(v)} end)
        }

      _ ->
        empty_ps()
    end
  end

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  @doc """
  A command line shortened to what identifies the process: no environment
  assignments, no Python boot code, no launcher flags, executables by name,
  paths relative to the project (`roots`, as given and resolved).
  """
  def short_command(cmd, roots \\ []) do
    cmd =
      Enum.reduce(roots, cmd, fn root, acc -> String.replace(acc, root <> "/", "") end)
      |> String.replace(~r/(^|\s)[A-Z][A-Z0-9_]*=\S*/, "")
      |> String.replace(~r/ -c import sys,runpy;.*?run_name='__main__'\)/, "")
      |> String.replace(~r/ --fsize \d+ --grace \d+ --/, "")
      |> String.replace(~r/(^|\s)\S*\/env -i(?=\s)/, "")
      |> String.replace(~r/(^|\s)\S*\/priv\/sdk(?=\s|$)/, "")
      |> String.replace(
        ~r/\S*\/(universe_run|sandbox-exec|python3(?:\.\d+)?|bash|sh|elixir|claude|node)(?=\s|$)/,
        "\\1"
      )
      |> String.replace(~r/\S*\/Python(?=\s|$)/, "python3")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(cmd) > 200, do: String.slice(cmd, 0, 199) <> "…", else: cmd
  end

  ## Labels

  defp main_module(id, pid, modules) do
    cond do
      is_atom(id) and id != :undefined and Code.ensure_loaded?(id) and Map.has_key?(@roles, id) ->
        id

      match?([m] when is_atom(m), modules) and modules != [:dynamic] ->
        hd(modules)

      true ->
        initial_module(pid)
    end
  end

  defp initial_module(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        case dict[:"$initial_call"] do
          {m, _, _} -> m
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp role_key(id, module) do
    cond do
      Map.has_key?(@roles, id) -> id
      Map.has_key?(@roles, module) -> module
      true -> nil
    end
  end

  defp display_name(id, pid, module) do
    # A child id we have a role for reads better than a library's internal
    # registered name (Anubis registers its supervisor under a long atom).
    registered = if Map.has_key?(@roles, id), do: nil, else: Process.info(pid, :registered_name)

    case registered do
      {:registered_name, name} when is_atom(name) and name != [] -> inspect(name)
      _ when is_atom(id) and id != :undefined -> inspect(id)
      _ -> if module, do: "#{inspect(module)} #{inspect(pid)}", else: inspect(pid)
    end
  end

  defp key(id, _pid) when is_atom(id) and id != :undefined, do: inspect(id)
  defp key(_id, pid), do: inspect(pid)

  defp own?(id), do: id in @own

  # Task.Supervisor is built on DynamicSupervisor, so check it first.
  defp kind(:supervisor, module, pid) do
    cond do
      module == Task.Supervisor ->
        :task_supervisor

      module == DynamicSupervisor or match?(%DynamicSupervisor{}, get_state(pid)) ->
        :dynamic_supervisor

      true ->
        :supervisor
    end
  end

  defp kind(:worker, module, _pid) do
    cond do
      module == Task.Supervised -> :task
      module in [Registry, Registry.Partition] -> :registry
      module && behaviour?(module, GenServer) -> :genserver
      true -> :process
    end
  end

  defp behaviour?(module, behaviour) do
    Code.ensure_loaded?(module) and
      behaviour in (module.module_info(:attributes)
                    |> Keyword.get_values(:behaviour)
                    |> List.flatten())
  end

  defp strategy(pid) do
    case get_state(pid) do
      %DynamicSupervisor{strategy: s} -> s
      # :supervisor's state record: {:state, name, strategy, ...}
      state when is_tuple(state) and elem(state, 0) == :state -> elem(state, 2)
      _ -> nil
    end
  end

  defp get_state(pid) do
    :sys.get_state(pid, @state_timeout)
  catch
    :exit, _ -> nil
  end

  ## Totals

  defp totals(nil), do: %{processes: 0, workers: 0, os: 0}

  defp totals(root) do
    nodes = flatten(root)

    %{
      processes: length(nodes),
      workers: Enum.count(nodes, &(&1.status != nil)),
      os: nodes |> Enum.flat_map(& &1.os) |> Enum.map(&count_os/1) |> Enum.sum(),
      beam_processes: :erlang.system_info(:process_count),
      beam_memory: :erlang.memory(:total)
    }
  end

  defp count_os(n), do: 1 + (n.children |> Enum.map(&count_os/1) |> Enum.sum())

  @doc "All nodes of a tree, depth first."
  def flatten(nil), do: []
  def flatten(node), do: [node | Enum.flat_map(node.children, &flatten/1)]
end
