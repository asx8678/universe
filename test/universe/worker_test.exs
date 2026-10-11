defmodule Universe.WorkerTest do
  use ExUnit.Case, async: true

  alias Universe.{EventLog, Paths, Worker}

  # IDs far above anything Universe.Tick hands out in the test run.
  defp start(code, opts \\ []) do
    id = 800_000 + System.unique_integer([:positive])

    spec = %{
      id: id,
      label: "t#{id}",
      tick: 0,
      lang: Keyword.get(opts, :lang, "bash"),
      code: code,
      budget: Map.merge(%{wall_s: 30, out_kb: 256}, Map.new(Keyword.get(opts, :budget, []))),
      leases: Keyword.get(opts, :leases, []),
      notify: self()
    }

    {:ok, _pid} = Worker.start(spec)
    id
  end

  defp await(id, timeout \\ 15_000) do
    assert_receive {:worker_exit, ^id, summary}, timeout
    summary
  end

  test "exit 0 is done; stdout, stderr and last lines are captured" do
    id = start("echo one; echo two; echo oops >&2")
    s = await(id)

    assert s["status"] == "done"
    assert s["code"] == 0
    assert s["last_out"] == "two"
    assert s["last_err"] == "oops"
    assert File.read!(Path.join(Worker.run_dir(id), "stdout")) == "one\ntwo\n"

    assert Enum.map(EventLog.for_id(id), & &1["type"]) |> Enum.uniq() |> Enum.sort() ==
             ~w(exit spawn stderr stdout)
  end

  test "output events carry whole lines, even when a line arrives in pieces" do
    id = start("printf 'half '; sleep 0.1; printf 'and half\\n'; printf 'no newline'")
    await(id)
    :ok = EventLog.sync()

    texts = for e <- EventLog.for_id(id), e["type"] == "stdout", do: e["data"]["text"]
    assert Enum.join(texts) == "half and half\nno newline"
    refute "half " in texts
  end

  test "a process printing line by line is logged in a few batches" do
    id =
      start("import sys\nfor i in range(2000):\n    print('line', i, flush=True)", lang: "python")

    await(id)
    :ok = EventLog.sync()

    texts = for e <- EventLog.for_id(id), e["type"] == "stdout", do: e["data"]["text"]
    assert length(texts) < 25
    assert Enum.join(texts) == File.read!(Path.join(Worker.run_dir(id), "stdout"))
    assert Enum.all?(texts, &String.ends_with?(&1, "\n"))
  end

  test "a prompt without a newline still shows while the process waits" do
    id = start("printf 'Continue? '; sleep 1.5")
    Process.sleep(900)
    :ok = EventLog.sync()

    assert [%{"data" => %{"text" => "Continue? "}}] =
             Enum.filter(EventLog.for_id(id), &(&1["type"] == "stdout"))

    await(id)
  end

  test "the worker's own HOME shows as ~/ in last lines" do
    s = await(start("echo \"$HOME/.ssh\"; exit 1"))
    assert s["last_out"] == "~/.ssh"
  end

  test "non-zero exit is failed, with the code" do
    assert %{"status" => "failed", "code" => 3} = await(start("exit 3"))
  end

  test "python and elixir runners work" do
    assert %{"status" => "done", "last_out" => "py 3"} =
             await(start("print('py', 1 + 2)", lang: "python"))

    assert %{"status" => "done", "last_out" => "ex 3"} =
             await(start("IO.puts(\"ex \#{1 + 2}\")", lang: "elixir"))
  end

  test "the wall budget kills the whole process tree" do
    id = start("sleep 30 & sleep 30; echo never", budget: [wall_s: 1])
    s = await(id)

    assert s["status"] == "budget"
    assert Enum.any?(EventLog.for_id(id), &(&1["type"] == "budget_hit"))
    {out, _} = System.cmd("pgrep", ["-f", "runs/#{id}/"])
    assert out == ""
  end

  test "kill/1 stops a running worker" do
    id = start("echo started; sleep 30")
    Process.sleep(300)
    Worker.kill(id)
    assert %{"status" => "killed"} = await(id)
  end

  test "output past out_kb stays on disk but not in events" do
    id = start("head -c 300000 /dev/zero | tr '\\0' 'x'", budget: [out_kb: 1])
    assert %{"status" => "done"} = await(id)

    events = EventLog.for_id(id) |> Enum.filter(&(&1["type"] == "stdout"))

    in_events =
      events |> Enum.map(&(&1["data"]["text"] || "")) |> Enum.map(&byte_size/1) |> Enum.sum()

    assert in_events <= 1024
    assert Enum.any?(events, &(&1["data"]["truncated"] == true))
    assert File.stat!(Path.join(Worker.run_dir(id), "stdout")).size == 300_000
  end

  test "invalid UTF-8 output still produces valid events" do
    id = start("printf 'ok \\377\\376 bytes\\n'")
    assert %{"status" => "done", "last_out" => last} = await(id)
    assert last =~ "ok"
    assert String.valid?(last)
  end

  describe "isolation (sandbox-exec)" do
    @describetag :isolation

    setup do
      root = Paths.project_root()
      File.mkdir_p!(Path.join(root, "leased"))
      File.mkdir_p!(Path.join(root, "src"))
      :ok
    end

    test "writes inside the lease succeed, outside it they fail" do
      name = "w#{System.unique_integer([:positive])}"
      code = "echo in > leased/#{name} && echo ok; echo out > src/#{name}"
      assert %{"status" => "failed", "last_out" => "ok"} = await(start(code, leases: ["leased"]))

      root = Paths.project_root()
      assert File.read!(Path.join([root, "leased", name])) == "in\n"
      refute File.exists?(Path.join([root, "src", name]))
    end

    test "no network for snippets" do
      code =
        "import socket; socket.create_connection(('1.1.1.1', 53), timeout=3); print('connected')"

      assert %{"status" => "failed"} = await(start(code, lang: "python"))
    end

    test "the token and the rest of .universe are unreadable" do
      File.write!(Paths.token_file(), "do-not-read")
      assert %{"status" => "failed"} = await(start("cat .universe/token"))
    end

    test "messages name paths relative to the project" do
      %{"last_err" => err} = await(start("echo x > src/nope.txt"))
      assert err =~ "main.sh: line 1: src/nope.txt"
      refute err =~ Paths.project_root()
    end
  end
end
