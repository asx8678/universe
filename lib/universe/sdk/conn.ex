defmodule Universe.SDK.Conn do
  @moduledoc """
  One worker's SDK connection: newline-delimited JSON both ways.

  Worker → kernel (`rid` echoes back in the reply):

      {"op":"hello","id":5,"token":"..."}                      must come first
      {"rid":1,"op":"put","name":"orders","value":[...],"kind":"table"}
      {"rid":2,"op":"put_file","name":"report","path":"out/report.pdf"}
      {"rid":3,"op":"get","handle":"h:5/orders"}
      {"rid":4,"op":"progress","text":"scanning 800/1240"}
      {"rid":5,"op":"ask","question":"Use the new tokens file?"}  blocks for the reply
      {"rid":6,"op":"call","service":"pg","fn":"query","args":{...},"timeout_s":60}
      {"rid":7,"op":"serve","name":"pg","fns":["query"],"describe":"...","sigs":{...}}
      {"rid":8,"op":"services","names":["pg"]}       fns, describe and sigs of each
      {"rid":9,"op":"preview","handle":"h:5/orders"}  a handle's bounded preview
      {"rid":10,"op":"inbox"}                         steers for the call in progress
      {"op":"result","cid":9,"ok":true,"value":...}              answer to an invoke

  Kernel → worker:

      {"rid":1,"ok":true,"result":"h:5/orders"}  |  {"rid":1,"ok":false,"error":"..."}
      {"op":"invoke","cid":9,"fn":"query","args":{...},"timeout_ms":59000}   services only

  Events: `get` (handle reads and previews), `call` with `"via" => "sdk"`
  and a matching `call_done` when the answer comes back, `put`, `progress`,
  `steer_dropped`; `ask`, `serve` and `steer` are logged by the Tick.
  `{"op":"steers_dropped","texts":[...],"reason":"..."}` lets a service
  report steers it fetched but could not deliver.

  An agent's connections may `call` only the code services it was given
  (`allow`, from its token); everyone else may call any service.

  Each invocation carries its caller: the call directive's ID, or nil for a
  worker's own `U.call`. A `steer` from the model (`steer/3`, from the Tick)
  is accepted only for the invocation in flight, and for that caller when it
  names one; it waits in the inbox (at most @max_inbox) until the service
  fetches it with `inbox`. One still there when the invocation ends is
  dropped and logged.

  Invocations of a service are handed to it one at a time. `timeout_ms` is
  what is left of the caller's timeout; an invocation whose caller has
  already given up while it waited in the queue is dropped, not sent, and
  one that gets no `result` in time is failed so the next can go (its late
  result is ignored). At most @max_queue calls wait per service.

  Before `hello` a connection may send at most @preauth_bytes and must say
  hello within @hello_ms. A line that isn't JSON is answered with an error
  carrying its `rid` when one can be read from it (and fails the invocation
  it answers, by `cid`), so no client waits forever.
  """

  use GenServer, restart: :temporary

  alias Universe.{EventLog, Handles, Isolation, Paths, Services, Tick, Worker}

  @progress_burst 3
  @max_buffer 72 * 1024 * 1024
  @preauth_bytes 64 * 1024
  @hello_ms 10_000
  @max_queue 1_000
  @max_file_bytes 64 * 1024 * 1024
  @copy_timeout_ms 30_000
  @default_call_timeout_s 60
  @max_call_timeout_s 1800
  @max_inbox 20
  # put_file copies (and other blocking requests) running at once.
  @max_tasks 16
  @max_params 32

  def start_link(sock), do: GenServer.start_link(__MODULE__, sock)

  @doc """
  Hands `steer` to the invocation in flight on `conn`; with a `caller`, only
  if it is that caller's. `:ok`, or
  `{:error, :idle | :queued | :ended | :full | :unresponsive}`.
  """
  def steer(conn, steer, caller) do
    GenServer.call(conn, {:steer, steer, caller}, 2_000)
  catch
    :exit, {:timeout, _} -> {:error, :unresponsive}
    :exit, _ -> {:error, :ended}
  end

  @impl true
  def init(sock) do
    {:ok,
     %{
       sock: sock,
       buf: "",
       worker: nil,
       tick: nil,
       allow: :any,
       inbox: [],
       service: nil,
       queue: :queue.new(),
       inflight: nil,
       next_cid: 1,
       tasks: MapSet.new(),
       # Progress is logged at most @progress_burst at once, then one per
       # second; in between only the latest text is kept (see progress/2).
       progress_tokens: @progress_burst,
       progress_at: System.monotonic_time(:millisecond),
       progress_pending: nil,
       progress_timer: nil
     }}
  end

  @impl true
  def handle_info(:go, state) do
    :ok = :inet.setopts(state.sock, active: :once)
    Process.send_after(self(), :hello_timeout, @hello_ms)
    {:noreply, state}
  end

  def handle_info(:hello_timeout, %{worker: nil} = state), do: {:stop, :normal, state}
  def handle_info(:hello_timeout, state), do: {:noreply, state}

  def handle_info({:tcp, sock, data}, %{sock: sock} = state) do
    buf = state.buf <> data
    limit = if state.worker, do: @max_buffer, else: @preauth_bytes

    cond do
      byte_size(buf) > limit ->
        send_line(state, %{
          "ok" => false,
          "error" => "message over #{div(limit, 1024)} KB; connection closed"
        })

        {:stop, :normal, state}

      # Only split when the new data ends a line: re-scanning a long
      # unfinished line on every chunk would be quadratic.
      :binary.match(data, "\n") == :nomatch ->
        :inet.setopts(sock, active: :once)
        {:noreply, %{state | buf: buf}}

      true ->
        {lines, rest} = split_lines(buf)
        state = Enum.reduce(lines, %{state | buf: rest}, &handle_line/2)
        :inet.setopts(sock, active: :once)
        {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, _}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _, _}, state), do: {:stop, :normal, state}

  def handle_info({:reply, rid, result, task}, state) do
    reply(state, rid, result)
    {:noreply, %{state | tasks: MapSet.delete(state.tasks, task)}}
  end

  # A service that didn't answer in time: fail that call, serve the next.
  def handle_info({:invoke_timeout, cid}, %{inflight: {cid, from, _timer, _caller}} = state) do
    GenServer.reply(from, {:error, "service did not answer in time"})
    {:noreply, state |> drop_steers() |> Map.put(:inflight, nil) |> dispatch()}
  end

  def handle_info({:invoke_timeout, _cid}, state), do: {:noreply, state}

  def handle_info(:flush_progress, state),
    do: {:noreply, %{state | progress_timer: nil} |> progress(nil)}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:invoke, fun, args, timeout_ms, caller}, from, state) do
    if :queue.len(state.queue) >= @max_queue do
      {:reply, {:error, "service is busy: #{@max_queue} calls already waiting"}, state}
    else
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      entry = {fun, args, from, deadline, caller}
      {:noreply, %{state | queue: :queue.in(entry, state.queue)} |> dispatch()}
    end
  end

  # A steer is for the invocation in flight, and when it names a caller (a
  # call directive), for that caller's: never for whichever runs next.
  def handle_call({:steer, steer, caller}, _from, state) do
    cond do
      state.inflight == nil ->
        {:reply, {:error, :idle}, state}

      caller != nil and elem(state.inflight, 3) != caller ->
        queued? = Enum.any?(:queue.to_list(state.queue), &(elem(&1, 4) == caller))
        {:reply, {:error, if(queued?, do: :queued, else: :ended)}, state}

      length(state.inbox) >= @max_inbox ->
        {:reply, {:error, :full}, state}

      true ->
        {:reply, :ok, %{state | inbox: state.inbox ++ [steer]}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.progress_pending, do: event(state, "progress", %{"text" => state.progress_pending})
    closed = {:error, "service connection closed"}
    if state.inflight, do: GenServer.reply(elem(state.inflight, 1), closed)
    # Blocking requests of this connection (ask, call) have no one to answer.
    Enum.each(state.tasks, &Process.exit(&1, :kill))
    for {_, _, from, _, _} <- :queue.to_list(state.queue), do: GenServer.reply(from, closed)
    :gen_tcp.close(state.sock)
  end

  ## Progress

  # A token bucket: bursts up to @progress_burst events, then one per second.
  # Text that arrives without a token waits (only the latest) for the next.
  defp progress(state, text) do
    now = System.monotonic_time(:millisecond)
    tokens = min(@progress_burst, state.progress_tokens + (now - state.progress_at) / 1000)
    text = text || state.progress_pending
    state = %{state | progress_tokens: tokens, progress_at: now}

    cond do
      is_nil(text) ->
        state

      tokens >= 1 ->
        event(state, "progress", %{"text" => text})
        %{state | progress_tokens: tokens - 1, progress_pending: nil}

      state.progress_timer ->
        %{state | progress_pending: text}

      true ->
        wait = ceil((1 - tokens) * 1000)

        %{
          state
          | progress_pending: text,
            progress_timer: Process.send_after(self(), :flush_progress, wait)
        }
    end
  end

  ## Requests

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{} = msg} ->
        handle_msg(msg, state)

      _ ->
        # NaN and Infinity (Python's json emits them) are the usual cause.
        error = "invalid JSON (NaN and Infinity can't be sent)"
        rid = number_field(line, "rid")
        send_line(state, %{"rid" => rid, "ok" => false, "error" => error})

        case {number_field(line, "cid"), state.inflight} do
          {cid, {cid, from, timer, _caller}} when is_integer(cid) ->
            Process.cancel_timer(timer)
            GenServer.reply(from, {:error, "the service's result was not valid JSON"})
            state |> drop_steers() |> Map.put(:inflight, nil) |> dispatch()

          _ ->
            state
        end
    end
  end

  defp number_field(line, key) do
    case Regex.run(~r/"#{key}"\s*:\s*(\d{1,12})/, line) do
      [_, n] -> String.to_integer(n)
      nil -> nil
    end
  end

  defp handle_msg(%{"op" => "hello", "id" => id, "token" => token} = msg, %{worker: nil} = state) do
    case Services.token_owner(token) do
      {:ok, ^id, tick, allow} ->
        reply(state, msg["rid"], {:ok, "hello ##{id}"})
        %{state | worker: id, tick: tick, allow: allow}

      _ ->
        reply(state, msg["rid"], {:error, "bad credentials"})
        state
    end
  end

  defp handle_msg(msg, %{worker: nil} = state) do
    reply(state, msg["rid"], {:error, "send hello first"})
    state
  end

  defp handle_msg(%{"op" => "put", "name" => name} = msg, state) do
    result =
      with {:ok, handle, meta} <- Handles.put(state.worker, name, msg["value"], msg["kind"]) do
        event(state, "put", %{
          "handle" => handle,
          "kind" => meta["kind"],
          "summary" => meta["summary"]
        })

        {:ok, handle}
      end

    reply(state, msg["rid"], result)
    state
  end

  # The copy can take up to @copy_timeout_ms; it runs beside the connection
  # so invocations and results keep flowing meanwhile.
  defp handle_msg(%{"op" => "put_file", "name" => name, "path" => path} = msg, state) do
    if MapSet.size(state.tasks) >= @max_tasks do
      reply(
        state,
        msg["rid"],
        {:error, "put_file: #{@max_tasks} requests already running on this connection"}
      )

      state
    else
      ctx = Map.take(state, [:worker, :tick])
      async(state, msg["rid"], fn -> put_file(ctx, name, path) end)
    end
  end

  defp handle_msg(%{"op" => "get", "handle" => handle} = msg, state) do
    result = Handles.get(handle)
    # Logged so the observer can draw handle → reader.
    shown =
      if is_binary(handle), do: String.slice(handle, 0, 200), else: inspect(handle, limit: 5)

    event(state, "get", %{"handle" => shown, "ok" => match?({:ok, _}, result)})
    reply(state, msg["rid"], result)
    state
  end

  defp handle_msg(%{"op" => "progress", "text" => text} = msg, state) when is_binary(text) do
    reply(state, msg["rid"], {:ok, true})
    progress(state, String.slice(text, 0, 300))
  end

  defp handle_msg(%{"op" => "ask", "question" => q} = msg, state) when is_binary(q) do
    worker = state.worker
    async(state, msg["rid"], fn -> Tick.ask(worker, String.slice(q, 0, 2000)) end)
  end

  defp handle_msg(%{"op" => "call", "service" => service, "fn" => fun} = msg, state)
       when is_binary(service) and is_binary(fun) do
    case may_call(state, service) do
      :ok ->
        sdk_call(state, msg, service, fun)

      {:error, _} = refused ->
        reply(state, msg["rid"], refused)
        state
    end
  end

  # What an agent's tools are built from: each named service's functions,
  # description and signatures, for the services this connection may call.
  defp handle_msg(%{"op" => "services", "names" => names} = msg, state) when is_list(names) do
    infos =
      for name <- Enum.uniq(names), is_binary(name), may_call(state, name) == :ok do
        case Services.lookup(name) do
          {:ok, info} ->
            %{
              "name" => name,
              "live" => true,
              "fns" => info.fns,
              "describe" => info.describe,
              "sigs" => Map.get(info, :sigs, %{})
            }

          :error ->
            %{"name" => name, "live" => false}
        end
      end

    reply(state, msg["rid"], {:ok, infos})
    state
  end

  defp handle_msg(%{"op" => "preview", "handle" => handle} = msg, state) when is_binary(handle) do
    result = Handles.preview(handle)

    event(state, "get", %{
      "handle" => String.slice(handle, 0, 200),
      "ok" => match?({:ok, _}, result),
      "preview" => true
    })

    reply(state, msg["rid"], result)
    state
  end

  defp handle_msg(%{"op" => "inbox"} = msg, state) do
    reply(state, msg["rid"], {:ok, state.inbox})
    %{state | inbox: []}
  end

  defp handle_msg(%{"op" => "serve", "name" => name} = msg, state) when is_binary(name) do
    fns = msg["fns"] |> List.wrap() |> Enum.filter(&is_binary/1)
    describe = if is_binary(msg["describe"]), do: String.slice(msg["describe"], 0, 500), else: ""

    info = %{
      id: state.worker,
      conn: self(),
      fns: fns,
      describe: describe,
      sigs: sigs(msg["sigs"], fns),
      # Agents can't call agents (yet): an agent's own service is marked.
      agent: state.allow != :any
    }

    result =
      cond do
        not Handles.valid_name?(name) ->
          {:error, "service name must be 1-64 chars of letters, digits, _ . -"}

        state.service ->
          {:error, "already serving #{state.service}"}

        # The Tick approves the serve and registers it in one step, so a
        # refused serve is never routable.
        true ->
          with :ok <- Tick.service_ready(state.worker, name, info), do: {:ok, true}
      end

    reply(state, msg["rid"], result)
    if result == {:ok, true}, do: %{state | service: name}, else: state
  end

  defp handle_msg(
         %{"op" => "result", "cid" => cid} = msg,
         %{inflight: {cid, from, timer, _caller}} = state
       ) do
    Process.cancel_timer(timer)

    answer =
      if msg["ok"] == true,
        do: {:ok, msg["value"]},
        else: {:error, text(msg["error"] || "service function failed")}

    GenServer.reply(from, answer)
    state |> drop_steers() |> Map.put(:inflight, nil) |> dispatch()
  end

  defp handle_msg(%{"op" => "result"}, state), do: state

  # Steers the service fetched but could not deliver (its task timed out).
  defp handle_msg(%{"op" => "steers_dropped", "texts" => [_ | _] = texts} = msg, state) do
    texts = Enum.filter(texts, &is_binary/1)

    if texts != [] do
      reason = if is_binary(msg["reason"]), do: String.slice(msg["reason"], 0, 200)

      event(state, "steer_dropped", %{
        "count" => length(texts),
        "text" => String.slice(hd(texts), 0, 200),
        "reason" => reason || "the service could not deliver them"
      })
    end

    reply(state, msg["rid"], {:ok, true})
    state
  end

  defp handle_msg(msg, state) do
    reply(state, msg["rid"], {:error, "unknown or malformed op #{inspect(msg["op"])}"})
    state
  end

  defp sdk_call(state, msg, service, fun) do
    timeout = call_timeout(msg["timeout_s"])
    # The task holds only what it needs, not a copy of the whole state.
    ctx = Map.take(state, [:worker, :tick])
    args = msg["args"]

    async(state, msg["rid"], fn ->
      # "via sdk": a worker's own U.call, as opposed to a call directive.
      data = %{"service" => service, "fn" => fun, "via" => "sdk"}

      data =
        case args do
          %{"prompt" => p} when is_binary(p) -> Map.put(data, "prompt", String.slice(p, 0, 4000))
          _ -> data
        end

      # A task (prompt) is logged when it starts, since it can take minutes;
      # a plain function call once, when it is answered.
      task? = Map.has_key?(data, "prompt")
      if task?, do: event(ctx, "call", data)
      started = System.monotonic_time(:millisecond)
      result = Services.invoke(service, fun, args, timeout * 1000)

      done = %{
        "ok" => match?({:ok, _}, result),
        "wall_ms" => System.monotonic_time(:millisecond) - started
      }

      if task?,
        do: event(ctx, "call_done", Map.merge(%{"service" => service, "fn" => fun}, done)),
        else: event(ctx, "call", Map.merge(data, done))

      result
    end)
  end

  ## Helpers

  defp put_file(ctx, name, path) do
    with {:ok, source} <- readable_source(ctx.worker, path),
         {:ok, copy} <- sandboxed_copy(ctx.worker, source) do
      try do
        with {:ok, handle, meta} <-
               Handles.put_file(ctx.worker, name, copy, Path.basename(source)) do
          event(ctx, "put", %{
            "handle" => handle,
            "kind" => "file",
            "summary" => meta["summary"]
          })

          {:ok, handle}
        end
      after
        File.rm(copy)
      end
    end
  end

  defp may_call(%{allow: :any}, _service), do: :ok

  defp may_call(%{allow: allow}, service) do
    cond do
      service not in allow and allow == [] ->
        {:error, "this agent was given no services, so it can't call #{service}"}

      service not in allow ->
        {:error, "this agent may call only #{Enum.join(allow, ", ")}, not #{service}"}

      match?({:ok, %{agent: true}}, Services.lookup(service)) ->
        {:error, "#{service} is an agent; agents can't call agents"}

      true ->
        :ok
    end
  end

  # Signatures of the service's functions, bounded: an agent's tool schemas
  # are built from them. `{fn => %{params, required, doc, extra}}`.
  defp sigs(sigs, fns) when is_map(sigs) do
    for fun <- Enum.take(fns, 64), %{} = sig <- [sigs[fun]], into: %{} do
      params = sig["params"] |> List.wrap() |> Enum.filter(&param?/1) |> Enum.take(@max_params)
      doc = if is_binary(sig["doc"]), do: String.slice(sig["doc"], 0, 500), else: ""

      {fun,
       %{
         "params" => params,
         "required" => sig["required"] |> List.wrap() |> Enum.filter(&(&1 in params)),
         "doc" => doc,
         "extra" => sig["extra"] == true
       }}
    end
  end

  defp sigs(_, _fns), do: %{}

  defp param?(p), do: is_binary(p) and Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]{0,63}$/, p)

  # Steers for a call that just ended were never fetched: they are dropped.
  defp drop_steers(%{inbox: []} = state), do: state

  defp drop_steers(state) do
    event(state, "steer_dropped", %{
      "count" => length(state.inbox),
      "text" => String.slice(hd(state.inbox)["text"], 0, 200),
      "reason" => "the task ended before it took them"
    })

    %{state | inbox: []}
  end

  # Blocking work runs in a linked task; the connection keeps serving.
  defp async(state, rid, fun) do
    conn = self()
    {:ok, task} = Task.start_link(fn -> send(conn, {:reply, rid, fun.(), self()}) end)
    %{state | tasks: MapSet.put(state.tasks, task)}
  end

  defp text(v) when is_binary(v), do: v
  defp text(v), do: inspect(v, limit: 50)

  defp dispatch(%{inflight: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {fun, args, from, deadline, caller}}, queue} ->
        left = deadline - System.monotonic_time(:millisecond)

        if left <= 0 do
          # The caller has timed out already; don't start work nobody awaits.
          dispatch(%{state | queue: queue})
        else
          cid = state.next_cid

          send_line(state, %{
            "op" => "invoke",
            "cid" => cid,
            "fn" => fun,
            "args" => args,
            "timeout_ms" => left
          })

          timer = Process.send_after(self(), {:invoke_timeout, cid}, left)
          %{state | queue: queue, inflight: {cid, from, timer, caller}, next_cid: cid + 1}
        end

      {:empty, _} ->
        state
    end
  end

  defp dispatch(state), do: state

  defp reply(state, rid, {:ok, result}),
    do: send_line(state, %{"rid" => rid, "ok" => true, "result" => result})

  defp reply(state, rid, {:error, reason}),
    do: send_line(state, %{"rid" => rid, "ok" => false, "error" => text(reason)})

  defp send_line(state, map), do: :gen_tcp.send(state.sock, [Jason.encode_to_iodata!(map), ?\n])

  defp split_lines(buf) do
    parts = String.split(buf, "\n")
    {Enum.drop(parts, -1) |> Enum.reject(&(&1 == "")), List.last(parts)}
  end

  defp event(state, type, data),
    do: EventLog.append(type, tick: state.tick, id: state.worker, data: data)

  defp call_timeout(t) when is_integer(t) and t > 0, do: min(t, @max_call_timeout_s)
  defp call_timeout(_), do: @default_call_timeout_s

  # put_file may read the project and the worker's own run dir, nothing else.
  defp readable_source(worker, path) when is_binary(path) do
    root = Isolation.realpath(Paths.project_root())
    run_dir = Isolation.realpath(Worker.run_dir(worker))
    universe = Path.join(root, ".universe")
    source = path |> Path.expand(Paths.project_root()) |> Isolation.realpath()

    cond do
      String.starts_with?(source, run_dir <> "/") ->
        {:ok, source}

      String.starts_with?(source, universe <> "/") ->
        {:error, "#{path}: .universe/ is off limits"}

      String.starts_with?(source, root <> "/") ->
        {:ok, source}

      true ->
        {:error, "#{path}: only files in the project or the run directory"}
    end
  end

  defp readable_source(_worker, _path), do: {:error, "path must be a string"}

  # The copy runs inside the worker's own sandbox, never with the daemon's
  # rights: if the worker swaps the checked path for a symlink to a secret,
  # the sandbox refuses to read it. The reader opens without blocking and
  # checks it got a regular file (a FIFO would hang a plain `head`).
  defp sandboxed_copy(worker, source) do
    root = Paths.project_root()
    dir = Path.join(Paths.universe_dir(), "tmp")
    File.mkdir_p!(dir)
    copy = Path.join(dir, "put_file-#{worker}-#{System.unique_integer([:positive])}")

    spec = %{
      root: root,
      run_dir: Worker.run_dir(worker),
      writable: [],
      network: :none,
      profile: "#{worker}-put_file"
    }

    with {:ok, reader} <- reader_argv(source) do
      copy_with(Isolation.adapter().wrap(reader, spec), copy, source, root)
    end
  end

  defp copy_with(argv, copy, source, root) do
    task =
      Task.async(fn ->
        System.cmd(hd(argv), tl(argv),
          into: File.stream!(copy),
          cd: root,
          stderr_to_stdout: false
        )
      end)

    case Task.yield(task, @copy_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_, 0}} ->
        if File.stat!(copy).size <= @max_file_bytes,
          do: {:ok, copy},
          else: discard(copy, "file is over 64 MB")

      {:ok, {_, _code}} ->
        discard(
          copy,
          "cannot read #{Path.relative_to(source, root)} (not a regular file, or not allowed)"
        )

      _ ->
        discard(copy, "reading the file took over #{div(@copy_timeout_ms, 1000)}s")
    end
  end

  defp discard(copy, reason) do
    File.rm(copy)
    {:error, reason}
  end

  # A reader opens without blocking, checks it got a regular file, copies at
  # most `limit` bytes and ends itself at the copy timeout: killing the
  # waiting task doesn't reach an OS process stuck in a slow read. Each
  # takes `source limit seconds`. python3 first, then perl (macOS and most
  # Linux hosts have it), then sh with `head` under a watchdog, so workers
  # in any language can put_file on a host without python3.
  @readers [
    {"python3", ["-I", "-c"],
     """
     import os, signal, stat, sys
     signal.alarm(int(sys.argv[3]))
     fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
     if not stat.S_ISREG(os.fstat(fd).st_mode): sys.exit(3)
     os.set_blocking(fd, True)
     left = int(sys.argv[2])
     while left > 0:
         chunk = os.read(fd, min(1 << 20, left))
         if not chunk: break
         sys.stdout.buffer.write(chunk); left -= len(chunk)
     """, []},
    {"perl", ["-e"],
     """
     use Fcntl; my ($path, $left, $secs) = @ARGV; alarm($secs);
     sysopen(my $fh, $path, O_RDONLY | O_NONBLOCK) or exit 2;
     exit 3 unless -f $fh;
     fcntl($fh, F_SETFL, fcntl($fh, F_GETFL, 0) & ~O_NONBLOCK);
     binmode STDOUT;
     while ($left > 0) {
       my $n = sysread($fh, my $buf, $left < 1048576 ? $left : 1048576);
       last unless $n; print STDOUT $buf; $left -= $n;
     }
     """, []},
    # `-f` then `head` can race a swap to a FIFO; the watchdog bounds it.
    {"sh", ["-c"],
     """
     [ -f "$1" ] || exit 3
     head -c "$2" "$1" & p=$!
     ( sleep "$3"; kill -9 "$p" ) >/dev/null 2>&1 & w=$!
     wait "$p"; s=$?; kill "$w" 2>/dev/null; exit "$s"
     """, ["put_file"]}
  ]

  # (`sh -c` takes $0 before the arguments.)

  defp reader_argv(source) do
    Enum.find_value(@readers, {:error, "put_file needs python3, perl or sh"}, fn {program, _, _,
                                                                                  _} ->
      case reader_argv(source, program) do
        {:ok, argv} -> {:ok, argv}
        :error -> nil
      end
    end)
  end

  @doc false
  # One reader's argv by program name, or :error when it isn't installed.
  def reader_argv(source, program) do
    limit = Integer.to_string(@max_file_bytes + 1)
    secs = Integer.to_string(div(@copy_timeout_ms, 1000) + 1)

    with {_, flags, script, arg0} <- List.keyfind(@readers, program, 0),
         path when is_binary(path) <- System.find_executable(program) do
      {:ok, [path | flags] ++ [script | arg0] ++ [source, limit, secs]}
    else
      _ -> :error
    end
  end
end
