defmodule Universe.Worker do
  @moduledoc """
  One worker ID: owns one OS process tree through the `universe_run` launcher.

  The launcher puts the command in its own process group and kills the whole
  group when the command exits, when told to (`kill/1`, budgets) or when this
  GenServer dies and the port closes. So a worker can never outlive its
  GenServer, and agent code never runs inside the kernel's BEAM. Processes
  that leave the group on purpose (`setsid`) are a known gap.

  Two kinds: `"run"` snippets (wall budget, exit ends them) and `"serve"`
  services (no wall budget unless given; they call `U.serve` and stay up).

  An agent service (`lang: "agent"`) runs `priv/sdk/agent_bridge.py`, which
  keeps one headless `claude` session and serves its `task` function. The
  `claude` CLI needs your login (under `$HOME`) and the Claude API, so an
  agent is not wrapped in the Seatbelt profile; it runs `claude --restricted`
  instead: no code-running tools, file tools confined to the project, writes
  only to its leases (permission rules), and `.universe/` denied.

  Files in `.universe/runs/<id>/`: the code file, `stdout`, `stderr`,
  `sandbox.sb`, `token`. Output goes to disk in full; events carry it only up
  to the `out_kb` budget per stream.

  When the process ends the worker appends an `exit` event, then sends
  `{:worker_exit, id, summary}` to its `:notify` pid.
  """

  use GenServer, restart: :temporary

  alias Universe.{EventLog, Isolation, Paths, Secrets, Services}

  @runners %{
    "python" => "main.py",
    "bash" => "main.sh",
    "elixir" => "main.exs"
  }

  @python_boot "import sys,runpy;sys.path.insert(0,sys.argv[1]);import universe;m=sys.argv[2];" <>
                 "sys.argv=[m];runpy.run_path(m,init_globals={'U':universe},run_name='__main__')"

  @grace_ms 2_000
  @line_max 300
  @default_fsize 1_073_741_824

  def langs, do: Map.keys(@runners)

  @doc "Starts a worker under `Universe.WorkerSup`."
  def start(spec), do: DynamicSupervisor.start_child(Universe.WorkerSup, {__MODULE__, spec})

  def start_link(spec), do: GenServer.start_link(__MODULE__, spec, name: via(spec.id))

  def via(id), do: {:via, Registry, {Universe.Registry, id}}

  def whereis(id) do
    case Registry.lookup(Universe.Registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Stops the worker's process group: SIGTERM, then SIGKILL after a grace period."
  def kill(id, why \\ :kill) do
    if pid = whereis(id), do: GenServer.cast(pid, {:kill, why})
    :ok
  end

  @doc "Directory holding a worker's files."
  def run_dir(id), do: Path.join(Paths.runs_dir(), Integer.to_string(id))

  @doc "Name of the code file for a language."
  def code_file("agent"), do: "agent.json"
  def code_file(lang), do: Map.fetch!(@runners, lang)

  defp code_text(%{lang: "agent", agent: agent} = state, root) do
    Jason.encode!(%{
      "service" => state.service,
      "purpose" => agent.purpose,
      "model" => agent.model,
      "tools" => agent.tools,
      "leases" => state.leases,
      "resume" => Map.get(agent, :resume, true),
      "session_file" => Path.join([Paths.universe_dir(), "agents", "#{state.service}.json"]),
      "root" => root,
      "claude" => claude_bin()
    })
  end

  defp code_text(state, _root), do: state.code

  @doc "The claude CLI agents run: `config :universe, claude_bin` or the one on PATH."
  def claude_bin do
    Application.get_env(:universe, :claude_bin) || System.find_executable("claude") || "claude"
  end

  @doc """
  Directory of the SDK client libraries, symlinks resolved: in development
  `_build/*/lib/universe/priv` links into the repo, and the sandbox can't
  follow a link that lives under `$HOME`.
  """
  def sdk_dir, do: Isolation.realpath(Application.app_dir(:universe, "priv/sdk"))

  @impl true
  def init(spec) do
    Process.flag(:trap_exit, true)

    state = %{
      id: spec.id,
      label: spec.label,
      tick: spec.tick,
      kind: Map.get(spec, :kind, "run"),
      lang: spec.lang,
      code: spec.code,
      agent: Map.get(spec, :agent),
      wall_s: spec.budget[:wall_s],
      mem_mb: spec.budget[:mem_mb],
      out_cap: spec.budget.out_kb * 1024,
      leases: spec.leases,
      network: Map.get(spec, :network, []),
      service: Map.get(spec, :service),
      notify: Map.get(spec, :notify, Universe.Tick),
      run_dir: run_dir(spec.id),
      token: random(24),
      port: nil,
      os_pid: nil,
      started_ms: System.monotonic_time(:millisecond),
      killed_by: nil,
      files: %{},
      emitted: %{stdout: 0, stderr: 0},
      truncated: %{stdout: false, stderr: false},
      partial: %{stdout: "", stderr: ""},
      last: %{stdout: nil, stderr: nil},
      strip: strip_prefixes(run_dir(spec.id)),
      done: false
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    root = Paths.project_root()
    File.mkdir_p!(Path.join(state.run_dir, "tmp"))
    File.mkdir_p!(Path.join(state.run_dir, "home"))
    code_path = Path.join(state.run_dir, code_file(state.lang))
    File.write!(code_path, code_text(state, root))
    token_path = Path.join(state.run_dir, "token")
    File.write!(token_path, state.token)
    File.chmod!(token_path, 0o600)
    Services.put_token(state.token, state.id, state.tick)

    files =
      Map.new([:stdout, :stderr], fn stream ->
        {:ok, io} =
          File.open(Path.join(state.run_dir, Atom.to_string(stream)), [:write, :binary, :raw])

        {stream, io}
      end)

    state = %{state | files: files}

    event(state, "spawn", %{
      "label" => state.label,
      "lang" => state.lang,
      "kind" => state.kind,
      "budget" => %{
        "wall_s" => state.wall_s,
        "out_kb" => div(state.out_cap, 1024),
        "mem_mb" => state.mem_mb
      },
      "leases" => state.leases,
      "network" => state.network
    })

    case command(state, code_path) do
      {:error, reason} ->
        finish(state, %{"status" => "failed", "code" => nil, "signal" => nil, "reason" => reason})

      {:ok, argv} ->
        spec = %{
          root: root,
          run_dir: state.run_dir,
          writable: Enum.map(state.leases, &Path.join(root, &1)),
          network: if(state.network == [], do: :none, else: {:hosts, state.network}),
          readable: [sdk_dir()],
          socket: Universe.SDK.Listener.socket_path()
        }

        argv = if state.lang == "agent", do: argv, else: Isolation.adapter().wrap(argv, spec)

        args =
          ["--fsize", Integer.to_string(fsize()), "--grace", Integer.to_string(@grace_ms), "--"] ++
            env_args(state) ++ argv

        port =
          Port.open({:spawn_executable, launcher()}, [
            :binary,
            {:packet, 4},
            :use_stdio,
            args: args,
            cd: root
          ])

        if state.wall_s, do: Process.send_after(self(), :wall_budget, state.wall_s * 1000)
        {:noreply, %{state | port: port}}
    end
  end

  @impl true
  def handle_cast({:kill, why}, %{port: port, killed_by: nil, done: false} = state)
      when port != nil do
    if why == :mem,
      do: event(state, "budget_hit", %{"budget" => "mem_mb", "limit" => state.mem_mb})

    Port.command(port, "K")
    {:noreply, %{state | killed_by: if(why == :mem, do: :mem, else: :kill)}}
  end

  def handle_cast({:kill, _why}, state), do: {:noreply, state}

  @impl true
  def handle_info({port, {:data, <<"P", pid::32>>}}, %{port: port} = state) do
    if state.mem_mb, do: Universe.GC.watch_memory(state.id, pid, state.mem_mb)
    {:noreply, %{state | os_pid: pid}}
  end

  def handle_info({port, {:data, <<"O", chunk::binary>>}}, %{port: port} = state),
    do: {:noreply, output(state, :stdout, chunk)}

  def handle_info({port, {:data, <<"E", chunk::binary>>}}, %{port: port} = state),
    do: {:noreply, output(state, :stderr, chunk)}

  def handle_info({port, {:data, <<"X", code::32, signal::32>>}}, %{port: port} = state) do
    {status, reason} =
      case {state.killed_by, code} do
        {:budget, _} -> {"budget", "wall budget #{state.wall_s}s hit"}
        {:mem, _} -> {"budget", "memory budget #{state.mem_mb} MB hit"}
        {:kill, _} -> {"killed", nil}
        {nil, 0} -> {"done", nil}
        {nil, _} -> {"failed", nil}
      end

    summary = %{"status" => status, "code" => code, "signal" => nonzero(signal)}
    finish(state, if(reason, do: Map.put(summary, "reason", reason), else: summary))
  end

  def handle_info(:wall_budget, %{done: false, killed_by: nil, port: port} = state)
      when port != nil do
    event(state, "budget_hit", %{"budget" => "wall_s", "limit" => state.wall_s})
    Port.command(port, "K")
    {:noreply, %{state | killed_by: :budget}}
  end

  def handle_info(:wall_budget, state), do: {:noreply, state}

  def handle_info({:EXIT, port, reason}, %{port: port, done: false} = state) do
    finish(state, %{
      "status" => "failed",
      "code" => nil,
      "signal" => nil,
      "reason" => "launcher exited: #{inspect(reason)}"
    })
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Closing the port makes the launcher SIGKILL the group.
    if state.port && not state.done, do: safe_close(state.port)
    Services.delete_token(state.token)
    Universe.GC.unwatch_memory(state.id)
    Enum.each(state.files, fn {_, io} -> File.close(io) end)
  end

  ## Command

  defp command(state, code_path) do
    runner =
      case state.lang do
        "python" ->
          {"python3", fn exe -> [exe, "-I", "-u", "-c", @python_boot, sdk_dir(), code_path] end}

        "bash" ->
          {"bash", fn exe -> [exe, code_path] end}

        "elixir" ->
          {"elixir", fn exe -> [exe, "-r", Path.join(sdk_dir(), "universe.exs"), code_path] end}

        "agent" ->
          bridge = Path.join(sdk_dir(), "agent_bridge.py")
          {"python3", fn exe -> [exe, "-I", "-u", "-c", @python_boot, sdk_dir(), bridge] end}
      end

    {bin, build} = runner

    case System.find_executable(bin) do
      nil -> {:error, "#{bin} not found on PATH"}
      exe -> {:ok, build.(exe)}
    end
  end

  defp env_args(state) do
    secrets = if state.kind == "serve" and state.service, do: Secrets.env(state.service), else: []

    # claude finds your login through HOME and USER (keychain).
    home =
      if state.lang == "agent",
        do: [
          "HOME=#{System.user_home!()}",
          "USER=#{System.get_env("USER", "")}",
          "UNIVERSE_AGENT_CONFIG=#{Path.join(state.run_dir, "agent.json")}"
        ],
        else: ["HOME=#{Path.join(state.run_dir, "home")}"]

    [
      "/usr/bin/env",
      "-i",
      "PATH=#{System.get_env("PATH", "/usr/bin:/bin")}"
    ] ++
      home ++
      [
        "TMPDIR=#{Path.join(state.run_dir, "tmp")}",
        "LANG=en_US.UTF-8",
        "UNIVERSE_ID=#{state.id}",
        "UNIVERSE_RUN_DIR=#{state.run_dir}",
        "UNIVERSE_SOCK=#{Universe.SDK.Listener.socket_path()}",
        "UNIVERSE_TOKEN_FILE=#{Path.join(state.run_dir, "token")}"
      ] ++ Enum.map(secrets, fn {k, v} -> "#{k}=#{v}" end)
  end

  ## Output

  defp output(state, stream, chunk) do
    :ok = :file.write(state.files[stream], chunk)
    state = track_lines(state, stream, chunk)
    emitted = state.emitted[stream]

    cond do
      emitted < state.out_cap ->
        part = binary_part(chunk, 0, min(byte_size(chunk), state.out_cap - emitted))
        event(state, Atom.to_string(stream), %{"text" => utf8(part)})
        state = put_in(state.emitted[stream], emitted + byte_size(part))

        if byte_size(part) < byte_size(chunk), do: mark_truncated(state, stream), else: state

      state.truncated[stream] ->
        state

      true ->
        mark_truncated(state, stream)
    end
  end

  defp mark_truncated(state, stream) do
    event(state, Atom.to_string(stream), %{
      "truncated" => true,
      "note" => "output past #{div(state.out_cap, 1024)} KB is kept on disk only"
    })

    put_in(state.truncated[stream], true)
  end

  # Remembers the last non-empty line of each stream, for digest lines.
  defp track_lines(state, stream, chunk) do
    [partial | complete] = String.split(state.partial[stream] <> chunk, "\n") |> Enum.reverse()

    last =
      case Enum.find(complete, &(String.trim(&1) != "")) do
        nil -> state.last[stream]
        line -> clip(line, state.strip)
      end

    # Keep the pending partial line bounded.
    partial =
      if byte_size(partial) > 4096,
        do: binary_part(partial, byte_size(partial) - 4096, 4096),
        else: partial

    %{
      state
      | partial: Map.put(state.partial, stream, partial),
        last: Map.put(state.last, stream, last)
    }
  end

  defp last_line(state, stream) do
    case String.trim(state.partial[stream]) do
      "" -> state.last[stream]
      _ -> clip(state.partial[stream], state.strip)
    end
  end

  ## Exit

  defp finish(state, summary) do
    summary =
      Map.merge(summary, %{
        "wall_ms" => System.monotonic_time(:millisecond) - state.started_ms,
        "last_out" => last_line(state, :stdout),
        "last_err" => last_line(state, :stderr)
      })

    event(state, "exit", summary)
    send(state.notify, {:worker_exit, state.id, summary})
    {:stop, :normal, %{state | done: true}}
  end

  ## Helpers

  defp event(state, type, data),
    do: EventLog.append(type, tick: state.tick, id: state.id, data: data)

  defp launcher, do: Application.app_dir(:universe, "priv/bin/universe_run")
  defp fsize, do: Application.get_env(:universe, :max_file_bytes, @default_fsize)

  defp nonzero(0), do: nil
  defp nonzero(n), do: n

  defp random(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp clip(line, strip) do
    line = line |> utf8() |> String.trim() |> shorten(strip)
    if String.length(line) > @line_max, do: String.slice(line, 0, @line_max) <> "…", else: line
  end

  # Digest lines read better with paths relative to the project: an error at
  # "/Users/…/proj/.universe/runs/9/main.sh: line 1" becomes "main.sh: line 1".
  defp strip_prefixes(run_dir) do
    root = Paths.project_root()

    [run_dir, Isolation.realpath(run_dir), root, Isolation.realpath(root)]
    |> Enum.uniq()
    |> Enum.map(&(&1 <> "/"))
  end

  defp shorten(line, prefixes), do: Enum.reduce(prefixes, line, &String.replace(&2, &1, ""))

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  @doc false
  # Invalid bytes become U+FFFD so every event stays valid JSON.
  def utf8(bin) do
    case :unicode.characters_to_binary(bin) do
      text when is_binary(text) -> text
      {:incomplete, text, _rest} -> text
      {:error, text, <<_bad, rest::binary>>} -> text <> "�" <> utf8(rest)
    end
  end
end
