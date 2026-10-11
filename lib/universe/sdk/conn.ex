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
      {"rid":7,"op":"serve","name":"pg","fns":["query"],"describe":"..."}
      {"op":"result","cid":9,"ok":true,"value":...}              answer to an invoke

  Kernel → worker:

      {"rid":1,"ok":true,"result":"h:5/orders"}  |  {"rid":1,"ok":false,"error":"..."}
      {"op":"invoke","cid":9,"fn":"query","args":{...},"timeout_ms":59000}   services only

  Events: `get` (handle reads), `call` with `"via" => "sdk"` and a matching
  `call_done` when the answer comes back, `put`, `progress`; `ask` and
  `serve` are logged by the Tick.

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

  def start_link(sock), do: GenServer.start_link(__MODULE__, sock)

  @impl true
  def init(sock) do
    {:ok,
     %{
       sock: sock,
       buf: "",
       worker: nil,
       tick: nil,
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
  def handle_info({:invoke_timeout, cid}, %{inflight: {cid, from, _timer}} = state) do
    GenServer.reply(from, {:error, "service did not answer in time"})
    {:noreply, dispatch(%{state | inflight: nil})}
  end

  def handle_info({:invoke_timeout, _cid}, state), do: {:noreply, state}

  def handle_info(:flush_progress, state),
    do: {:noreply, %{state | progress_timer: nil} |> progress(nil)}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:invoke, fun, args, timeout_ms}, from, state) do
    if :queue.len(state.queue) >= @max_queue do
      {:reply, {:error, "service is busy: #{@max_queue} calls already waiting"}, state}
    else
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      {:noreply,
       %{state | queue: :queue.in({fun, args, from, deadline}, state.queue)} |> dispatch()}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.progress_pending, do: event(state, "progress", %{"text" => state.progress_pending})
    closed = {:error, "service connection closed"}
    if state.inflight, do: GenServer.reply(elem(state.inflight, 1), closed)
    # Blocking requests of this connection (ask, call) have no one to answer.
    Enum.each(state.tasks, &Process.exit(&1, :kill))
    for {_, _, from, _} <- :queue.to_list(state.queue), do: GenServer.reply(from, closed)
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
          {cid, {cid, from, timer}} when is_integer(cid) ->
            Process.cancel_timer(timer)
            GenServer.reply(from, {:error, "the service's result was not valid JSON"})
            dispatch(%{state | inflight: nil})

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
      {:ok, ^id, tick} ->
        reply(state, msg["rid"], {:ok, "hello ##{id}"})
        %{state | worker: id, tick: tick}

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

  defp handle_msg(%{"op" => "put_file", "name" => name, "path" => path} = msg, state) do
    result =
      with {:ok, source} <- readable_source(state.worker, path),
           {:ok, copy} <- sandboxed_copy(state.worker, source) do
        try do
          with {:ok, handle, meta} <-
                 Handles.put_file(state.worker, name, copy, Path.basename(source)) do
            event(state, "put", %{
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

    reply(state, msg["rid"], result)
    state
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
    async(state, msg["rid"], fn -> Tick.ask(state.worker, String.slice(q, 0, 2000)) end)
  end

  defp handle_msg(%{"op" => "call", "service" => service, "fn" => fun} = msg, state)
       when is_binary(service) and is_binary(fun) do
    timeout = call_timeout(msg["timeout_s"])

    async(state, msg["rid"], fn ->
      # "via sdk": a worker's own U.call, as opposed to a call directive.
      data = %{"service" => service, "fn" => fun, "via" => "sdk"}

      data =
        case msg["args"] do
          %{"prompt" => p} when is_binary(p) -> Map.put(data, "prompt", String.slice(p, 0, 4000))
          _ -> data
        end

      # A task (prompt) is logged when it starts, since it can take minutes;
      # a plain function call once, when it is answered.
      task? = Map.has_key?(data, "prompt")
      if task?, do: event(state, "call", data)
      started = System.monotonic_time(:millisecond)
      result = Services.invoke(service, fun, msg["args"], timeout * 1000)

      done = %{
        "ok" => match?({:ok, _}, result),
        "wall_ms" => System.monotonic_time(:millisecond) - started
      }

      if task?,
        do: event(state, "call_done", Map.merge(%{"service" => service, "fn" => fun}, done)),
        else: event(state, "call", Map.merge(data, done))

      result
    end)
  end

  defp handle_msg(%{"op" => "serve", "name" => name} = msg, state) when is_binary(name) do
    fns = msg["fns"] |> List.wrap() |> Enum.filter(&is_binary/1)
    describe = if is_binary(msg["describe"]), do: String.slice(msg["describe"], 0, 500), else: ""

    result =
      cond do
        not Handles.valid_name?(name) ->
          {:error, "service name must be 1-64 chars of letters, digits, _ . -"}

        state.service ->
          {:error, "already serving #{state.service}"}

        true ->
          with :ok <- Services.register(name, %{id: state.worker, fns: fns, describe: describe}),
               :ok <- Tick.service_ready(state.worker, name, fns, describe) do
            {:ok, true}
          end
      end

    reply(state, msg["rid"], result)
    if result == {:ok, true}, do: %{state | service: name}, else: state
  end

  defp handle_msg(
         %{"op" => "result", "cid" => cid} = msg,
         %{inflight: {cid, from, timer}} = state
       ) do
    Process.cancel_timer(timer)

    answer =
      if msg["ok"] == true,
        do: {:ok, msg["value"]},
        else: {:error, text(msg["error"] || "service function failed")}

    GenServer.reply(from, answer)
    dispatch(%{state | inflight: nil})
  end

  defp handle_msg(%{"op" => "result"}, state), do: state

  defp handle_msg(msg, state) do
    reply(state, msg["rid"], {:error, "unknown or malformed op #{inspect(msg["op"])}"})
    state
  end

  ## Helpers

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
      {{:value, {fun, args, from, deadline}}, queue} ->
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
          %{state | queue: queue, inflight: {cid, from, timer}, next_cid: cid + 1}
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

    argv = Isolation.adapter().wrap(reader_argv(source), spec)

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

  @reader """
  import os, stat, sys
  fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
  if not stat.S_ISREG(os.fstat(fd).st_mode): sys.exit(3)
  os.set_blocking(fd, True)
  left = int(sys.argv[2])
  while left > 0:
      chunk = os.read(fd, min(1 << 20, left))
      if not chunk: break
      sys.stdout.buffer.write(chunk); left -= len(chunk)
  """

  defp reader_argv(source) do
    limit = Integer.to_string(@max_file_bytes + 1)

    case System.find_executable("python3") do
      nil -> ["/usr/bin/head", "-c", limit, "--", source]
      py -> [py, "-I", "-c", @reader, source, limit]
    end
  end
end
