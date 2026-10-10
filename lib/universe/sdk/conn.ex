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

  Invocations of a service are handed to it one at a time. `timeout_ms` is
  what is left of the caller's timeout; an invocation whose caller has
  already given up while it waited in the queue is dropped, not sent.
  """

  use GenServer, restart: :temporary

  alias Universe.{EventLog, Handles, Isolation, Paths, Services, Tick, Worker}

  @max_buffer 72 * 1024 * 1024
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
       next_cid: 1
     }}
  end

  @impl true
  def handle_info(:go, state) do
    :ok = :inet.setopts(state.sock, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp, sock, data}, %{sock: sock} = state) do
    buf = state.buf <> data

    if byte_size(buf) > @max_buffer do
      send_line(state, %{"ok" => false, "error" => "message over 72 MB; connection closed"})
      {:stop, :normal, state}
    else
      {lines, rest} = split_lines(buf)
      state = Enum.reduce(lines, %{state | buf: rest}, &handle_line/2)
      :inet.setopts(sock, active: :once)
      {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, _}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _, _}, state), do: {:stop, :normal, state}

  def handle_info({:reply, rid, result}, state) do
    reply(state, rid, result)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:invoke, fun, args, timeout_ms}, from, state) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    {:noreply,
     %{state | queue: :queue.in({fun, args, from, deadline}, state.queue)} |> dispatch()}
  end

  @impl true
  def terminate(_reason, state) do
    closed = {:error, "service connection closed"}
    if state.inflight, do: GenServer.reply(elem(state.inflight, 1), closed)
    for {_, _, from, _} <- :queue.to_list(state.queue), do: GenServer.reply(from, closed)
    :gen_tcp.close(state.sock)
  end

  ## Requests

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{} = msg} -> handle_msg(msg, state)
      _ -> tap(state, &send_line(&1, %{"ok" => false, "error" => "invalid JSON"}))
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
           {:ok, handle, meta} <- Handles.put_file(state.worker, name, source) do
        event(state, "put", %{"handle" => handle, "kind" => "file", "summary" => meta["summary"]})
        {:ok, handle}
      end

    reply(state, msg["rid"], result)
    state
  end

  defp handle_msg(%{"op" => "get", "handle" => handle} = msg, state) do
    reply(state, msg["rid"], Handles.get(handle))
    state
  end

  defp handle_msg(%{"op" => "progress", "text" => text} = msg, state) when is_binary(text) do
    event(state, "progress", %{"text" => String.slice(text, 0, 300)})
    reply(state, msg["rid"], {:ok, true})
    state
  end

  defp handle_msg(%{"op" => "ask", "question" => q} = msg, state) when is_binary(q) do
    async(state, msg["rid"], fn -> Tick.ask(state.worker, String.slice(q, 0, 2000)) end)
  end

  defp handle_msg(%{"op" => "call", "service" => service, "fn" => fun} = msg, state)
       when is_binary(service) and is_binary(fun) do
    timeout = call_timeout(msg["timeout_s"])

    async(state, msg["rid"], fn ->
      event(state, "call", %{"service" => service, "fn" => fun})
      Services.invoke(service, fun, msg["args"], timeout * 1000)
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

  defp handle_msg(%{"op" => "result", "cid" => cid} = msg, %{inflight: {cid, from}} = state) do
    answer =
      if msg["ok"] == true,
        do: {:ok, msg["value"]},
        else: {:error, to_string(msg["error"] || "service function failed")}

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
    Task.start_link(fn -> send(conn, {:reply, rid, fun.()}) end)
    state
  end

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

          %{state | queue: queue, inflight: {cid, from}, next_cid: cid + 1}
        end

      {:empty, _} ->
        state
    end
  end

  defp dispatch(state), do: state

  defp reply(state, rid, {:ok, result}),
    do: send_line(state, %{"rid" => rid, "ok" => true, "result" => result})

  defp reply(state, rid, {:error, reason}),
    do: send_line(state, %{"rid" => rid, "ok" => false, "error" => to_string(reason)})

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
end
