defmodule Universe.AgentToolsTest do
  # An agent's services as MCP tools (priv/sdk/agent_mcp.py), the kernel's
  # allow-list, and steering a busy agent; against the fake `claude`
  # (test/support/bin/fake_claude), so no plan usage is spent.
  use ExUnit.Case, async: false

  alias Universe.{API, EventLog, Services, Worker}

  @fake Path.expand("../support/bin/fake_claude", __DIR__)

  setup do
    previous = Application.get_env(:universe, :claude_bin)
    Application.put_env(:universe, :claude_bin, @fake)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:universe, :claude_bin, previous),
        else: Application.delete_env(:universe, :claude_bin)
    end)
  end

  @numbers """
  def add(a, b):
      \"\"\"Adds two numbers.\"\"\"
      return a + b

  def rows(n, start=0):
      \"\"\"n rows of squares.\"\"\"
      return [{"i": i, "sq": i * i} for i in range(start, start + n)]

  U.serve(NAME, {"add": add, "rows": rows}, "test numbers")
  """

  defp uniq(label), do: "#{label}-#{System.unique_integer([:positive])}"

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

  defp numbers(name) do
    %{
      "op" => "serve",
      "label" => name,
      "lang" => "python",
      "code" => "NAME = #{inspect(name)}\n" <> @numbers
    }
  end

  defp agent(name, agent \\ %{}) do
    %{
      "op" => "serve",
      "label" => name,
      "agent" => Map.merge(%{"purpose" => "Answer questions about the data."}, agent)
    }
  end

  defp task(label, service, prompt),
    do: %{"op" => "call", "label" => label, "service" => service, "prompt" => prompt}

  defp steer(target, text, extra \\ %{}),
    do: Map.merge(%{"op" => "steer", "target" => target, "text" => text}, extra)

  defp args_of(id),
    do:
      Path.join([Worker.run_dir(id), "tmp", "fake_claude_args.json"])
      |> File.read!()
      |> Jason.decode!()

  defp arg(args, flag), do: Enum.at(args, Enum.find_index(args, &(&1 == flag)) + 1)

  # The agent's MCP server, started the way claude starts it: from mcp.json.
  defp open_mcp(agent_id) do
    config = Path.join(Worker.run_dir(agent_id), "mcp.json") |> File.read!() |> Jason.decode!()
    server = config["mcpServers"]["services"]
    env = for {k, v} <- server["env"], do: {String.to_charlist(k), String.to_charlist(v)}

    Port.open({:spawn_executable, server["command"]}, [
      :binary,
      :exit_status,
      {:line, 1_000_000},
      args: server["args"],
      env: env
    ])
  end

  defp rpc(port, id, method, params \\ %{}) do
    msg = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    true = Port.command(port, Jason.encode!(msg) <> "\n")
    reply_to(port, id)
  end

  defp reply_to(port, id) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode!(line) do
          %{"id" => ^id} = reply -> reply
          _other -> reply_to(port, id)
        end
    after
      15_000 -> flunk("no MCP reply to request #{id}")
    end
  end

  defp text_of(reply), do: reply["result"]["content"] |> hd() |> Map.fetch!("text")

  # A raw SDK connection with the agent's own credentials.
  defp sdk_as(agent_id) do
    path = Universe.SDK.Listener.socket_path()
    {:ok, sock} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false])
    token = Path.join(Worker.run_dir(agent_id), "token") |> File.read!() |> String.trim()

    :ok =
      :gen_tcp.send(
        sock,
        Jason.encode!(%{op: "hello", id: agent_id, token: token, rid: 1}) <> "\n"
      )

    {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
    assert %{"ok" => true} = Jason.decode!(line)
    sock
  end

  defp sdk_request(sock, msg) do
    :ok = :gen_tcp.send(sock, Jason.encode!(Map.put(msg, :rid, 2)) <> "\n")
    {:ok, line} = :gen_tcp.recv(sock, 0, 10_000)
    Jason.decode!(line)
  end

  describe "services as tools" do
    test "an agent's services are its MCP tools, with schemas from U.serve" do
      [svc, other, name] = [uniq("nums"), uniq("other"), uniq("analyst")]

      result =
        tick([
          numbers(svc),
          numbers(other),
          agent(name, %{"services" => [svc]}),
          task("t-#{name}", name, "hello")
        ])

      assert status(result, name) == "serving"
      agent_id = id_of(result, name)
      run_dir = Worker.run_dir(agent_id)

      args = args_of(agent_id)
      assert "--replay-user-messages" in args
      assert arg(args, "--mcp-config") == Path.join(run_dir, "mcp.json")
      assert Bitwise.band(File.stat!(Path.join(run_dir, "mcp.json")).mode, 0o777) == 0o600

      assert "mcp__services" in (arg(args, "--settings")
                                 |> Jason.decode!())["permissions"]["allow"]

      assert arg(args, "--system-prompt") =~ "mcp__services__"
      # The file names the token file, never the token.
      refute File.read!(Path.join(run_dir, "mcp.json")) =~ File.read!(Path.join(run_dir, "token"))

      port = open_mcp(agent_id)

      init =
        rpc(port, 1, "initialize", %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "0"}
        })

      assert init["result"]["protocolVersion"] == "2025-11-25"
      assert init["result"]["instructions"] =~ "handle_preview"

      tools = Map.new(rpc(port, 2, "tools/list")["result"]["tools"], &{&1["name"], &1})

      assert Enum.sort(Map.keys(tools)) ==
               Enum.sort(["#{svc}__add", "#{svc}__rows", "handle_preview"])

      add = tools["#{svc}__add"]
      assert add["description"] =~ "add of the #{svc} service: Adds two numbers."
      assert add["description"] =~ "test numbers"
      assert add["inputSchema"]["required"] == ["a", "b"]
      assert add["_meta"] == %{"anthropic/alwaysLoad" => true}
      rows = tools["#{svc}__rows"]["inputSchema"]

      assert {Enum.sort(Map.keys(rows["properties"])), rows["required"]} ==
               {["n", "start"], ["n"]}

      sum =
        rpc(port, 3, "tools/call", %{
          "name" => "#{svc}__add",
          "arguments" => %{"a" => 2, "b" => 3}
        })

      assert text_of(sum) == "5"

      big = rpc(port, 4, "tools/call", %{"name" => "#{svc}__rows", "arguments" => %{"n" => 2000}})
      assert text_of(big) =~ "stored as h:#{agent_id}/rows-1"
      assert text_of(big) =~ "2,000 rows × 2 cols"

      look =
        rpc(port, 5, "tools/call", %{
          "name" => "handle_preview",
          "arguments" => %{"handle" => "h:#{agent_id}/rows-1"}
        })

      assert text_of(look) =~ "h:#{agent_id}/rows-1 · table"

      bad = rpc(port, 6, "tools/call", %{"name" => "#{svc}__add", "arguments" => %{"a" => 1}})
      assert bad["result"]["isError"]
      assert text_of(bad) =~ "missing 1 required positional argument: 'b'"

      unknown = rpc(port, 7, "tools/call", %{"name" => "#{other}__add", "arguments" => %{}})
      assert unknown["result"]["isError"]

      # A malformed cancel must not kill the server.
      cancel = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => %{"x" => 1}}
      }

      true = Port.command(port, Jason.encode!(cancel) <> "\n")
      assert rpc(port, 8, "ping")["result"] == %{}

      # The agent's calls are its own: the observer draws agent → service.
      calls = EventLog.for_id(agent_id) |> Enum.filter(&(&1["type"] == "call"))
      assert Enum.any?(calls, &(&1["data"]["service"] == svc and &1["data"]["via"] == "sdk"))

      Port.close(port)
      for n <- [name, svc, other], do: kill(n)
    end

    test "the kernel lets an agent call only the services it was given" do
      [svc, other, name, bare] = [uniq("nums"), uniq("other"), uniq("scoped"), uniq("bare")]

      result =
        tick([
          numbers(svc),
          numbers(other),
          agent(name, %{"services" => [svc]}),
          agent(bare)
        ])

      sock = sdk_as(id_of(result, name))
      ok = sdk_request(sock, %{op: "call", service: svc, fn: "add", args: [1, 2]})
      assert ok == %{"rid" => 2, "ok" => true, "result" => 3}

      refused = sdk_request(sock, %{op: "call", service: other, fn: "add", args: [1, 2]})
      assert refused["error"] == "this agent may call only #{svc}, not #{other}"

      listed = sdk_request(sock, %{op: "services", names: [svc, other]})
      assert [%{"name" => ^svc, "live" => true, "fns" => ["add", "rows"]}] = listed["result"]
      :gen_tcp.close(sock)

      sock = sdk_as(id_of(result, bare))
      none = sdk_request(sock, %{op: "call", service: svc, fn: "add", args: [1, 2]})
      assert none["error"] == "this agent was given no services, so it can't call #{svc}"
      :gen_tcp.close(sock)

      for n <- [name, bare, svc, other], do: kill(n)
    end

    test "an agent served with its service in one tick starts once the service serves" do
      [svc, name] = [uniq("slow"), uniq("waiter")]

      slow = %{
        "op" => "serve",
        "label" => svc,
        "lang" => "python",
        "code" =>
          "import time\ntime.sleep(1)\nU.serve(#{inspect(svc)}, {'ping': lambda: 'pong'}, 'slow')"
      }

      # The agent comes first in the batch on purpose.
      result =
        tick([agent(name, %{"services" => [svc]}), slow], %{"ids" => [name], "timeout_s" => 20})

      assert status(result, name) == "serving"
      [agent_id, svc_id] = [id_of(result, name), id_of(result, svc)]

      queued = EventLog.for_id(agent_id) |> Enum.find(&(&1["type"] == "queued"))
      assert "##{svc_id}" in queued["data"]["after"]
      served = EventLog.for_id(svc_id) |> Enum.find(&(&1["type"] == "serve"))
      spawned = EventLog.for_id(agent_id) |> Enum.find(&(&1["type"] == "spawn"))
      assert spawned["seq"] > served["seq"]

      for n <- [name, svc], do: kill(n)
    end

    test "an agent's services must be live code services" do
      [a, b, pool, c, d] = [uniq("a"), uniq("b"), uniq("pool"), uniq("c"), uniq("d")]

      result =
        tick(
          [
            agent(a, %{"services" => ["nope-#{a}"]}),
            agent(b, %{"pool" => pool}),
            agent(c, %{"services" => [b]}),
            agent(d, %{"services" => [pool]})
          ],
          %{"timeout_s" => 10}
        )

      assert result.text =~
               "agent services: no live service nope-#{a}; serve it first or in the same tick"

      assert result.text =~ "agent services: #{b} is an agent; list code services"
      assert result.text =~ "agent services: #{pool} is an agent; list code services"
      kill(b)
    end
  end

  describe "steer" do
    test "a steer reaches a busy agent mid-task and shapes its answer" do
      name = uniq("busy")
      t = "w-#{name}"

      first =
        tick([agent(name), task(t, name, "WORK on it")], %{"ids" => [name], "timeout_s" => 15})

      assert status(first, name) == "serving"

      second = tick([steer(name, "only look at lib/")], %{"ids" => [t], "timeout_s" => 15})
      assert status(second, t) == "done"

      assert second.text =~
               "steered: Message from the orchestrator while you work on this task: only look at lib/"

      events = EventLog.for_id(id_of(first, name))

      assert Enum.any?(
               events,
               &(&1["type"] == "steer" and &1["data"]["text"] == "only look at lib/")
             )

      assert Enum.any?(
               events,
               &(&1["type"] == "progress" and &1["data"]["text"] =~ "steered: only look")
             )

      kill(name)
    end

    test "a steer the session takes in after its turn gets a turn of its own" do
      name = uniq("deaf")
      t = "d-#{name}"
      tick([agent(name), task(t, name, "DEAF now")], %{"ids" => [name], "timeout_s" => 15})

      second = tick([steer(t, "also count the tests")], %{"ids" => [t], "timeout_s" => 15})
      assert status(second, t) == "done"

      assert second.text =~
               "done #2: Message from the orchestrator while you work on this task: also count the tests"

      refute second.text =~ "deaf done"
      kill(name)
    end

    test "a steer with interrupt stops the turn, then goes in as the next one" do
      name = uniq("stop")
      t = "s-#{name}"
      tick([agent(name), task(t, name, "WORK hard")], %{"ids" => [name], "timeout_s" => 15})

      second =
        tick([steer(t, "stop and summarise", %{"interrupt" => true})], %{
          "ids" => [t],
          "timeout_s" => 15
        })

      assert status(second, t) == "done"

      assert second.text =~
               "done #2: Message from the orchestrator while you work on this task: stop and summarise"

      kill(name)
    end

    test "a steer turn that comes too late never becomes the next task's answer" do
      name = uniq("lazy")
      t = "z-#{name}"
      tick([agent(name), task(t, name, "SLOW then LAZY")], %{"ids" => [name], "timeout_s" => 15})

      # Lands while the task runs; the session only gets to it 7 s after its
      # result, past the bridge's 5 s wait.
      first = tick([steer(t, "count the tests too")], %{"ids" => [t], "timeout_s" => 30})
      assert status(first, t) == "done"
      assert first.text =~ "lazy done"

      next =
        tick([task("n-#{name}", name, "hello")], %{"ids" => ["n-#{name}"], "timeout_s" => 30})

      assert next.text =~ "done #3: hello"
      refute next.text =~ "count the tests too"
      kill(name)
    end

    test "a steer to an idle, asking or finished agent is rejected" do
      [name, asker] = [uniq("idle"), uniq("asker")]
      t = "i-#{name}"
      tick([agent(name), task(t, name, "hello")])

      result =
        tick(
          [
            steer(name, "x"),
            steer(t, "x"),
            steer("nobody-#{name}", "x"),
            agent(asker),
            task("q-#{asker}", asker, "ASK me")
          ],
          %{"ids" => ["q-#{asker}"], "until" => "any", "timeout_s" => 15}
        )

      assert result.text =~ "#{name} is idle: give it a task with call"
      assert result.text =~ "#{t} is done"
      assert result.text =~ "no worker nobody-#{name}"

      asking = tick([steer(asker, "x")], %{"timeout_s" => 0})
      assert asking.text =~ "#{asker} is asking: answer it with reply"

      tick([%{"op" => "reply", "target" => asker, "text" => "lib/a.ex"}], %{
        "ids" => ["q-#{asker}"]
      })

      for n <- [name, asker], do: kill(n)
    end

    test "a steer that reaches the agent after its task ended is dropped and reported" do
      name = uniq("late")
      tick([agent(name), task("l1-#{name}", name, "hello")])

      {:ok, %{conn: conn}} = Services.lookup(name)
      send(conn, {:steer, %{"text" => "too late", "interrupt" => false}})
      _ = :sys.get_state(conn)

      result = tick([task("l2-#{name}", name, "hello again")], %{"ids" => ["l2-#{name}"]})
      assert result.text =~ "a steer came after its task ended, so it was not delivered"
      # The next task never sees it.
      assert result.text =~ "done #2: hello again"
      kill(name)
    end
  end
end
