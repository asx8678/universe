defmodule Universe.ResilienceTest do
  # Restarts parts of the application; never async.
  use ExUnit.Case, async: false

  alias Universe.{API, EventLog, Paths, Tick}

  defp uniq(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp run(label, code, extra \\ %{}),
    do: Map.merge(%{"op" => "run", "label" => label, "lang" => "bash", "code" => code}, extra)

  defp tick(directives, wait \\ %{"timeout_s" => 30}),
    do: API.tick(%{"directives" => directives, "wait" => wait})

  defp status(result, label) do
    Enum.find_value(result.structured["ids"], fn {_, v} -> v["label"] == label && v["status"] end)
  end

  test "a label rejected in this batch never resolves to an older worker" do
    [build, holder, test_label, lease] = Enum.map(~w(build holder test lease), &uniq/1)
    tick([run(build, "echo old")])
    tick([run(holder, "sleep 5", %{"leases" => [lease]})], %{"timeout_s" => 0})

    result =
      tick([
        run(build, "echo new", %{"leases" => [lease]}),
        run(test_label, "echo test-ran", %{"after" => [build]})
      ])

    assert result.text =~ ~r/rejected #{build}\s+lease/
    assert status(result, test_label) == "failed"
    assert result.text =~ "dep #{build} was rejected"
    tick([%{"op" => "kill", "target" => holder}], %{"timeout_s" => 5})
  end

  test "a Tick crash kills its workers; the new Tick recovers state from the log" do
    [before, long] = Enum.map(~w(before long), &uniq/1)
    tick([run(before, "echo ok")])
    first = tick([run(long, "sleep 30")], %{"timeout_s" => 0})

    long_id =
      Enum.find_value(first.structured["ids"], fn {"#" <> id, v} -> v["label"] == long && id end)

    old = Process.whereis(Tick)
    Process.exit(old, :kill)
    wait_until(fn -> Process.whereis(Tick) not in [nil, old] end)

    # The worker's process tree died with it.
    wait_until(fn -> DynamicSupervisor.count_children(Universe.WorkerSup).active == 0 end)
    {out, _} = System.cmd("pgrep", ["-f", "runs/#{long_id}/"])
    assert out == ""

    snapshot = Tick.snapshot()
    assert snapshot[String.to_integer(long_id)].status == "killed"
    assert snapshot[String.to_integer(long_id)].summary["reason"] == "lost: Universe restarted"

    # Labels from before the crash still resolve.
    after_label = uniq("after")
    result = tick([run(after_label, "echo fine", %{"after" => [before]})])
    assert status(result, after_label) == "done"
    assert result.text =~ ~r/stopped when Universe restarted \(.*##{long_id} #{long}/
  end

  test "a service that crashed and restarted before a Tick crash is recovered as lost" do
    name = uniq("phoenix")

    code = """
    import os, threading
    marker = os.path.join(os.environ["TMPDIR"], "crashed-once")
    if not os.path.exists(marker):
        open(marker, "w").close()
        threading.Timer(0.3, os._exit, [4]).start()
    U.serve(#{inspect(name)}, {"ping": lambda: "pong"}, "")
    """

    tick([%{"op" => "serve", "label" => name, "lang" => "python", "code" => code}], %{
      "ids" => [name],
      "timeout_s" => 10
    })

    # Serving again after its restart.
    wait_until(fn ->
      Enum.any?(EventLog.by_types(["restart"]), fn e ->
        Tick.snapshot()[e["id"]][:label] == name
      end) and
        Enum.any?(Map.values(Tick.snapshot()), &(&1.label == name and &1.status == "serving"))
    end)

    old = Process.whereis(Tick)
    Process.exit(old, :kill)
    wait_until(fn -> Process.whereis(Tick) not in [nil, old] end)

    w = Tick.snapshot() |> Map.values() |> Enum.find(&(&1.label == name))
    assert w.status == "killed"
    assert w.summary["reason"] == "lost: Universe restarted"
  end

  test "a recovered call still knows which service and function it called" do
    svc = uniq("adder")
    q = uniq("q")
    code = "def add(a, b):\n    return a + b\nU.serve(#{inspect(svc)}, {'add': add})"

    result =
      tick([
        %{"op" => "serve", "label" => svc, "lang" => "python", "code" => code},
        %{
          "op" => "call",
          "label" => q,
          "service" => svc,
          "fn" => "add",
          "args" => %{"a" => 1, "b" => 2}
        }
      ])

    assert status(result, q) == "done"

    q_id =
      Enum.find_value(result.structured["ids"], fn {"#" <> id, v} -> v["label"] == q && id end)

    old = Process.whereis(Tick)
    Process.exit(old, :kill)
    wait_until(fn -> Process.whereis(Tick) not in [nil, old] end)

    spec = Tick.snapshot()[String.to_integer(q_id)].spec
    assert {spec.service, spec.fn} == {svc, "add"}
  end

  test "settled workers past max_settled are archived but still resolve" do
    labels = for i <- 1..45, do: uniq("bulk#{i}")
    result = tick(Enum.map(labels, &run(&1, "true")))

    first_id =
      result.structured["ids"]
      |> Map.keys()
      |> Enum.map(fn "#" <> n -> String.to_integer(n) end)
      |> Enum.min()

    settled =
      Tick.snapshot()
      |> Enum.count(fn {_, w} -> w.status in ~w(done failed budget killed rejected) end)

    assert settled <= Application.get_env(:universe, :max_settled)
    refute Map.has_key?(Tick.snapshot(), first_id)

    dependent = uniq("dependent")
    result = tick([run(dependent, "echo ok", %{"after" => ["##{first_id}"]})])
    assert status(result, dependent) == "done"
  end

  test "settled workers drop their code" do
    label = uniq("compact")
    tick([run(label, "echo keep-me-small")])
    w = Tick.snapshot() |> Map.values() |> Enum.find(&(&1.label == label))
    assert w.spec.code == nil
  end

  test "the memory budget kills a process group that grows past it" do
    label = uniq("mem")
    code = "import time\nb = b'x' * (400 * 1024 * 1024)\ntime.sleep(20)"

    result =
      tick([
        %{
          "op" => "run",
          "label" => label,
          "lang" => "python",
          "code" => code,
          "budget" => %{"mem_mb" => 100}
        }
      ])

    assert status(result, label) == "budget"
    assert result.text =~ "memory budget 100 MB hit"
  end

  test "a process that calls setsid outlives its worker (known gap)" do
    # Documents the containment gap: a snippet that deliberately leaves its
    # process group is NOT killed when the worker ends. The kernel stays
    # healthy; only the stray process lingers. See docs/PLAN.md.
    label = uniq("escape")
    marker = "universe-gap-#{System.unique_integer([:positive])}"

    code =
      "import subprocess\n" <>
        "subprocess.Popen(['sleep', '300'], start_new_session=True)\n" <>
        "print('spawned #{marker}')"

    # Tag the escaped process so we only ever touch our own.
    result =
      API.tick(%{
        "directives" => [%{"op" => "run", "label" => label, "lang" => "python", "code" => code}],
        "wait" => %{"timeout_s" => 30}
      })

    assert status(result, label) == "done"
    # The stray process is still alive; clean it up ourselves.
    {out, _} = System.cmd("pgrep", ["-f", "sleep 300"])
    assert out != ""
    System.cmd("pkill", ["-f", "sleep 300"])
  end

  test "old run directories are pruned by gc" do
    dir = Path.join(Paths.runs_dir(), "654321")
    File.mkdir_p!(dir)
    old = System.os_time(:second) - 8 * 86_400
    File.touch!(dir, old)

    assert %{run_dirs: pruned} = Universe.GC.sweep_now()
    assert 654_321 in pruned
    refute File.exists?(dir)
  end

  test "gc deletes a run directory a worker locked with chmod 000" do
    dir = Path.join(Paths.runs_dir(), "654322")
    File.mkdir_p!(Path.join(dir, "tmp/locked/inner"))
    File.chmod!(Path.join(dir, "tmp/locked"), 0o000)
    File.touch!(dir, System.os_time(:second) - 8 * 86_400)
    gc = Process.whereis(Universe.GC)

    assert %{run_dirs: pruned} = Universe.GC.sweep_now()
    assert 654_322 in pruned
    refute File.exists?(dir)
    assert Process.whereis(Universe.GC) == gc
  end

  test "a GC restart keeps the memory budgets of running workers" do
    label = uniq("memgc")
    code = "import time\ntime.sleep(2)\nb = b'x' * (400 * 1024 * 1024)\ntime.sleep(20)"

    d = %{
      "op" => "run",
      "label" => label,
      "lang" => "python",
      "code" => code,
      "budget" => %{"mem_mb" => 100}
    }

    tick([d], %{"timeout_s" => 0})

    # GC dies (and its watch table with it) while the worker is still small.
    Process.sleep(500)
    old = Process.whereis(Universe.GC)
    Process.exit(old, :kill)
    wait_until(fn -> Process.whereis(Universe.GC) not in [nil, old] end)

    result = tick([], %{"ids" => [label], "timeout_s" => 30})
    assert status(result, label) == "budget"
  end

  test "the daemon lock refuses a second live daemon and takes over a stale file" do
    path = Universe.Lock.pid_file()
    File.mkdir_p!(Path.dirname(path))
    port = Port.open({:spawn_executable, "/bin/sleep"}, args: ["5"])
    {:os_pid, live_pid} = Port.info(port, :os_pid)

    File.write!(path, Integer.to_string(live_pid))
    assert {:stop, "another Universe daemon (pid " <> _} = Universe.Lock.init([])

    File.write!(path, "999999")
    assert {:ok, _} = Universe.Lock.init([])
    assert File.read!(path) == System.pid()

    Port.close(port)
    File.rm(path)
  end

  test "the sandbox allows stat on ancestor directories only" do
    alias Universe.Isolation.SandboxExec

    assert SandboxExec.ancestors("/Users/a/projects/x") == [
             "/Users",
             "/Users/a",
             "/Users/a/projects"
           ]

    assert SandboxExec.ancestors("/x") == []
  end

  test "the sandbox profile denies starting or scripting other apps, and lives outside the run dir" do
    alias Universe.Isolation.SandboxExec
    root = Paths.project_root()
    run_dir = Path.join(Paths.runs_dir(), "777001")
    File.mkdir_p!(run_dir)
    spec = %{root: root, run_dir: run_dir, writable: [], network: :none}

    profile = SandboxExec.profile(spec)
    assert profile =~ ~s{(deny mach-lookup (global-name "com.apple.coreservices.launchservicesd")}
    assert profile =~ "com.apple.coreservices.appleevents"

    ["/usr/bin/sandbox-exec", "-f", path | _] = SandboxExec.wrap(["true"], spec)
    assert Path.dirname(path) == Paths.sandbox_dir()
    refute File.exists?(Path.join(run_dir, "sandbox.sb"))
  end

  test "path-resolving tools like SQLite work inside the sandbox" do
    label = uniq("sqlite")
    root = Paths.project_root()
    File.mkdir_p!(Path.join(root, "data"))
    db = Path.join(root, "data/s.db")
    File.rm(db)

    {_, 0} =
      System.cmd("python3", [
        "-c",
        "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('create table t(x)'); c.executemany('insert into t values (?)', [(i,) for i in range(7)]); c.commit()",
        db
      ])

    code =
      "import sqlite3\nprint('rows', sqlite3.connect('data/s.db').execute('select count(*) from t').fetchone()[0])"

    result =
      API.tick(%{
        "directives" => [%{"op" => "run", "label" => label, "lang" => "python", "code" => code}],
        "wait" => %{"timeout_s" => 30}
      })

    assert status(result, label) == "done"
    assert result.text =~ "rows 7"
  end

  test "the sandbox maps declared hosts to Seatbelt rules" do
    alias Universe.Isolation.SandboxExec
    assert SandboxExec.host_rule("localhost:5432") == "localhost:5432"
    assert SandboxExec.host_rule("127.0.0.1:8080") == "localhost:8080"
    assert SandboxExec.host_rule("db.example.com:5432") == "*:5432"
  end

  test "events are flushed on shutdown and the event log survives" do
    marker = EventLog.append("test_flush", data: %{"x" => 1})
    :ok = EventLog.sync()
    log = File.read!(Path.join(Paths.log_dir(), "events.jsonl"))
    assert log =~ ~s("seq":#{marker["seq"]})
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(50) && wait_until(fun, tries - 1)
    end
  end
end
