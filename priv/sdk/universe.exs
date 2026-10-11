# Universe SDK for Elixir workers. Loaded before every Elixir snippet
# (`elixir -r universe.exs main.exs`), so `U` is always available.
#
#     rows = U.call("pg", "query", %{"sql" => "select * from orders"})
#     handle = U.put("orders", rows)          # "h:5/orders"
#     U.progress("scanned 800/1240")
#     answer = U.ask("Use the new tokens file?")
#     U.serve("pg", %{"query" => fn %{"sql" => sql} -> ... end}, "Postgres reader")
#
# Service functions get the call's args like the Python client passes them: a
# list whose length is the function's arity is spread ([2, 40] -> f.(2, 40),
# [20] -> f.(20)), nil calls a 0-arity function, anything else (a map, one
# term) is passed as one argument.
# Uses the built-in JSON module (Elixir 1.18+), no dependencies.
defmodule U do
  @moduledoc false

  defmodule Error do
    defexception [:message]
  end

  def call(service, fun, args \\ nil, timeout_s \\ nil) do
    fields = %{"service" => service, "fn" => fun, "args" => args}
    request("call", if(timeout_s, do: Map.put(fields, "timeout_s", timeout_s), else: fields))
  end

  def put(name, value, kind \\ nil) do
    fields = %{"name" => name, "value" => value}
    request("put", if(kind, do: Map.put(fields, "kind", kind), else: fields))
  end

  def put_file(name, path), do: request("put_file", %{"name" => name, "path" => Path.expand(path)})

  def get(handle) do
    case request("get", %{"handle" => handle}) do
      %{"base64" => b64} = m when map_size(m) == 1 -> Base.decode64!(b64)
      value -> value
    end
  end

  def progress(text), do: request("progress", %{"text" => to_string(text)})
  def ask(question), do: request("ask", %{"question" => to_string(question)})

  def serve(name, fns, describe \\ "") when is_map(fns) and map_size(fns) > 0 do
    request("serve", %{"name" => name, "fns" => fns |> Map.keys() |> Enum.sort(), "describe" => describe})
    serve_loop(fns)
  end

  defp serve_loop(fns) do
    msg =
      case Process.get(:u_pending, []) do
        [next | rest] ->
          Process.put(:u_pending, rest)
          next

        [] ->
          read()
      end

    if msg["op"] == "invoke" do
      result =
        try do
          %{"op" => "result", "cid" => msg["cid"], "ok" => true, "value" => apply_args(Map.fetch!(fns, msg["fn"]), msg["args"])}
        rescue
          e -> %{"op" => "result", "cid" => msg["cid"], "ok" => false, "error" => Exception.message(e)}
        end

      send_msg(result)
    end

    serve_loop(fns)
  end

  defp apply_args(f, args) do
    {:arity, n} = Function.info(f, :arity)

    cond do
      n == 0 -> f.()
      is_list(args) and length(args) == n -> apply(f, args)
      true -> f.(args)
    end
  end

  ## Transport

  defp request(op, fields) do
    sock = connect()
    rid = Process.get(:u_rid, 0) + 1
    Process.put(:u_rid, rid)
    send_msg(Map.merge(fields, %{"op" => op, "rid" => rid}), sock)
    await(rid)
  end

  defp await(rid) do
    msg = read()

    cond do
      msg["op"] == "invoke" ->
        Process.put(:u_pending, Process.get(:u_pending, []) ++ [msg])
        await(rid)

      msg["rid"] == rid and msg["ok"] ->
        msg["result"]

      msg["rid"] == rid ->
        raise Error, message: msg["error"] || "request failed"

      true ->
        await(rid)
    end
  end

  defp connect do
    case Process.get(:u_sock) do
      nil ->
        path = System.get_env("UNIVERSE_SOCK") || raise Error, message: "not running inside Universe"
        {:ok, sock} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false, buffer: 1_048_576])
        Process.put(:u_sock, sock)
        id = String.to_integer(System.fetch_env!("UNIVERSE_ID"))
        token = System.get_env("UNIVERSE_TOKEN") || File.read!(System.fetch_env!("UNIVERSE_TOKEN_FILE"))
        send_msg(%{"op" => "hello", "id" => id, "token" => String.trim(token)}, sock)
        unless read()["ok"], do: raise(Error, message: "hello refused")
        sock

      sock ->
        sock
    end
  end

  defp send_msg(map, sock \\ Process.get(:u_sock)), do: :ok = :gen_tcp.send(sock, [JSON.encode!(map), ?\n])

  defp read, do: read_line(Process.get(:u_sock), "")

  # packet: :line may split long lines across receives; join until "\n".
  defp read_line(sock, acc) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, data} ->
        acc = acc <> data
        if String.ends_with?(acc, "\n"), do: JSON.decode!(acc), else: read_line(sock, acc)

      {:error, reason} ->
        raise Error, message: "connection to Universe closed: #{inspect(reason)}"
    end
  end
end
