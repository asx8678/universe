defmodule Universe.ServicesTest do
  # Services, the SDK and ask/reply, end to end through Universe.Tick.
  use ExUnit.Case, async: false

  alias Universe.{API, EventLog, Paths}

  defp uniq(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp py(label, code, extra \\ %{}),
    do: Map.merge(%{"op" => "run", "label" => label, "lang" => "python", "code" => code}, extra)

  defp tick(directives, wait \\ %{"timeout_s" => 30}),
    do: API.tick(%{"directives" => directives, "wait" => wait})

  defp status(result, label) do
    Enum.find_value(result.structured["ids"], fn {_, v} -> v["label"] == label && v["status"] end)
  end

  defp id_of(result, label) do
    Enum.find_value(result.structured["ids"], fn {"#" <> id, v} ->
      v["label"] == label && String.to_integer(id)
    end)
  end

  defp kill(label),
    do: tick([%{"op" => "kill", "target" => label}], %{"ids" => [label], "timeout_s" => 10})

  @adder """
  def add(a, b):
      return a + b

  def rows(n):
      return [{"i": i, "sq": i * i} for i in range(n)]

  def boom():
      raise ValueError("bad input")

  U.serve(NAME, {"add": add, "rows": rows, "boom": boom}, "test adder")
  """

  defp service(name, extra \\ %{}) do
    Map.merge(
      %{
        "op" => "serve",
        "label" => name,
        "lang" => "python",
        "code" => "NAME = #{inspect(name)}\n" <> @adder
      },
      extra
    )
  end

  test "U.put stores rows as a handle; the digest shows only its summary" do
    label = uniq("put")

    result =
      tick([
        py(label, "U.put('rows', [{'a': i, 'b': str(i)} for i in range(3)])\nprint('stored')")
      ])

    assert status(result, label) == "done"
    id = id_of(result, label)
    assert result.text =~ "→ h:#{id}/rows (3 rows × 2 cols)"
    refute result.text =~ "stored"

    preview = API.inspect(%{"target" => "h:#{id}/rows"}).text
    assert preview =~ "a  b"
    assert preview =~ "2  2"
  end

  test "serve then call in one tick; the call waits for the service" do
    name = uniq("adder")
    sum = uniq("sum")

    result =
      tick([
        %{
          "op" => "call",
          "label" => sum,
          "service" => name,
          "fn" => "add",
          "args" => %{"a" => 2, "b" => 3}
        },
        service(name)
      ])

    assert status(result, name) == "serving"
    assert status(result, sum) == "done"
    assert result.text =~ ~r/#{sum}\s+\S+ · → 5/
    assert result.text =~ "serving #{name} · fns: add, boom, rows · test adder"

    manifest = API.inspect(%{"target" => "manifest"}).text
    assert manifest =~ "#{name} (#"

    # A kill's wait holds until the service is really gone.
    assert status(kill(name), name) == "killed"
  end

  test "large call results become handles; errors are failed lines" do
    name = uniq("adder")
    big = uniq("big")
    bad = uniq("bad")
    tick([service(name)])

    result =
      tick([
        %{"op" => "call", "label" => big, "service" => name, "fn" => "rows", "args" => [500]},
        %{"op" => "call", "label" => bad, "service" => name, "fn" => "boom"}
      ])

    big_id = id_of(result, big)
    assert result.text =~ "→ h:#{big_id}/result (500 rows × 2 cols)"
    assert status(result, bad) == "failed"
    assert result.text =~ "ValueError: bad input"
    kill(name)
  end

  test "a snippet calls a service with U.call and stores the result" do
    name = uniq("adder")
    user = uniq("user")
    tick([service(name)])

    result =
      tick([py(user, "r = U.call(#{inspect(name)}, 'add', {'a': 40, 'b': 2})\nprint('got', r)")])

    assert status(result, user) == "done"
    assert result.text =~ "got 42"

    # The observer can draw worker → service and back.
    events = EventLog.for_id(id_of(result, user))
    call = Enum.find(events, &(&1["type"] == "call"))
    done = Enum.find(events, &(&1["type"] == "call_done"))
    assert %{"service" => ^name, "fn" => "add", "via" => "sdk"} = call["data"]
    assert %{"service" => ^name, "ok" => true} = done["data"]
    assert done["seq"] > call["seq"]
    kill(name)
  end

  test "handle reads are logged as get events" do
    label = uniq("reader")

    code =
      "h = U.put('nums', [1, 2, 3])\nprint(U.get(h))\nU.get('h:999999/none') if False else None"

    result = tick([py(label, code)])
    assert status(result, label) == "done"

    gets = EventLog.for_id(id_of(result, label)) |> Enum.filter(&(&1["type"] == "get"))
    assert [%{"data" => %{"ok" => true, "handle" => "h:" <> _}}] = gets
  end

  test "Elixir snippets have U too" do
    name = uniq("adder")
    ex = uniq("ex")
    tick([service(name)])

    code = """
    r = U.call(#{inspect(name)}, "add", %{"a" => 1, "b" => 2})
    U.put("answer", %{"r" => r})
    IO.puts("elixir got \#{r}")
    """

    result = tick([%{"op" => "run", "label" => ex, "lang" => "elixir", "code" => code}])
    assert status(result, ex) == "done"
    assert result.text =~ "h:#{id_of(result, ex)}/answer"
    kill(name)
  end

  test "U.progress sets the running line" do
    label = uniq("prog")
    code = "import time\nU.progress('scanning 800/1240')\ntime.sleep(5)"
    result = tick([py(label, code)], %{"timeout_s" => 2})

    assert status(result, label) == "running"
    assert result.text =~ "last: scanning 800/1240"
    kill(label)
  end

  test "U.ask wakes the model; a reply directive answers it" do
    label = uniq("asker")
    code = "a = U.ask('Use the new tokens file?')\nprint('answer was', a)"
    first = tick([py(label, code)])

    assert status(first, label) == "asking"
    assert first.text =~ "asks: Use the new tokens file?"

    second = tick([%{"op" => "reply", "target" => label, "text" => "yes, the new one"}])
    assert status(second, label) == "done"
    assert second.text =~ "answer was yes, the new one"

    again = tick([%{"op" => "reply", "target" => label, "text" => "x"}], %{"timeout_s" => 0})
    assert again.text =~ "is not asking"
  end

  test "a crashing service restarts, and gives up after 3 restarts in 60 s" do
    name = uniq("crashy")
    code = "import sys\nprint('starting')\nsys.exit(3)"

    result =
      tick([%{"op" => "serve", "label" => name, "lang" => "python", "code" => code}], %{
        "timeout_s" => 30
      })

    assert status(result, name) == "failed"
    assert result.text =~ "crashed 4 times in 60s"
    restarts = EventLog.for_id(id_of(result, name)) |> Enum.count(&(&1["type"] == "restart"))
    assert restarts == 3
  end

  test "calls to unknown services are rejected; duplicate service names too" do
    name = uniq("adder")
    tick([service(name)])

    result =
      tick(
        [
          %{"op" => "call", "label" => uniq("c"), "service" => "nope", "fn" => "x"},
          service(name) |> Map.put("label", uniq("dup")) |> Map.put("name", name)
        ],
        %{"timeout_s" => 0}
      )

    assert result.text =~ "no live service or agent pool nope"
    assert result.text =~ "service #{name} already runs as #"
    kill(name)
  end

  test "idle services are reaped by gc and reported" do
    name = uniq("idle")
    tick([service(name, %{"ttl_idle_s" => 1})])
    Process.sleep(1_300)
    assert %{idle: [_ | _]} = Universe.GC.sweep_now()

    # The stop is asynchronous; serving counts as settled, so poll.
    result =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        r = API.tick(%{"directives" => [], "since" => 0, "wait" => %{"timeout_s" => 0}})
        if r.text =~ ~r/#{name}\s+idle/, do: {:halt, r}, else: Process.sleep(100) && {:cont, r}
      end)

    assert result.text =~ ~r/killed\s+#{name}\s+idle 1s, stopped by gc/
  end

  test "secrets reach only their own service and are redacted from events" do
    name = uniq("sec")
    File.mkdir_p!(Paths.secrets_dir())
    File.write!(Path.join(Paths.secrets_dir(), "#{name}.env"), "DB_PASSWORD=s3cr3t-#{name}\n")

    code = """
    import os
    print("pw", os.environ.get("DB_PASSWORD"))
    U.serve(#{inspect(name)}, {"ping": lambda: "pong"}, "")
    """

    tick([%{"op" => "serve", "label" => name, "lang" => "python", "code" => code}])
    snippet = uniq("nosecret")
    result = tick([py(snippet, "import os\nprint('pw', os.environ.get('DB_PASSWORD'))")])

    assert result.text =~ "pw None"

    stdout =
      EventLog.since(0)
      |> Enum.filter(&(&1["type"] == "stdout"))
      |> Enum.map(& &1["data"]["text"])
      |> Enum.join()

    refute stdout =~ "s3cr3t-#{name}"
    assert stdout =~ "«redacted:#{name}.DB_PASSWORD»"
    kill(name)
  end

  test "services reach only the ports they declare" do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      for _ <- 1..2 do
        case :gen_tcp.accept(listen, 10_000) do
          {:ok, s} -> :gen_tcp.close(s)
          _ -> :ok
        end
      end
    end)

    name = uniq("net")

    code = """
    import socket
    def probe(port):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=2).close()
            return "open"
        except OSError as e:
            return "blocked"
    U.serve(#{inspect(name)}, {"probe": probe}, "")
    """

    tick([
      %{
        "op" => "serve",
        "label" => name,
        "lang" => "python",
        "code" => code,
        "network" => ["localhost:#{port}"]
      }
    ])

    ok = uniq("ok")
    no = uniq("no")

    result =
      tick([
        %{"op" => "call", "label" => ok, "service" => name, "fn" => "probe", "args" => [port]},
        %{"op" => "call", "label" => no, "service" => name, "fn" => "probe", "args" => [port + 1]}
      ])

    assert result.text =~ ~r/#{ok}\s+\S+ · → "open"/
    assert result.text =~ ~r/#{no}\s+\S+ · → "blocked"/
    kill(name)
    :gen_tcp.close(listen)
  end

  test "the SDK socket refuses bad credentials" do
    path = Universe.SDK.Listener.socket_path()
    {:ok, sock} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false])
    :ok = :gen_tcp.send(sock, ~s({"op":"hello","id":1,"token":"forged","rid":1}\n))
    {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
    assert %{"ok" => false, "error" => "bad credentials"} = Jason.decode!(line)

    :ok = :gen_tcp.send(sock, ~s({"op":"get","handle":"h:1/x","rid":2}\n))
    {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
    assert %{"ok" => false, "error" => "send hello first"} = Jason.decode!(line)
  end

  test "put_file accepts project and run-dir files, nothing else" do
    label = uniq("pf")

    code = """
    import os
    p = os.path.join(os.environ['TMPDIR'], 'report.txt')
    open(p, 'w').write('hello report')
    print(U.put_file('report', p))
    try:
        U.put_file('passwd', '/etc/passwd')
    except U.UniverseError as e:
        print('refused:', e)
    """

    result = tick([py(label, code)])
    assert status(result, label) == "done"
    assert result.text =~ ~r/h:\d+\/report \(file 12 B\)/
    card = API.inspect(%{"target" => "##{id_of(result, label)}"}).text
    assert card =~ "refused: /etc/passwd: only files in the project or the run directory"
  end
end
