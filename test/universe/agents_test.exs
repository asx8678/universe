defmodule Universe.AgentsTest do
  # Agent workers end to end through Universe.Tick, against a fake `claude`
  # (test/support/bin/fake_claude) so no plan usage is spent.
  use ExUnit.Case, async: false

  alias Universe.{API, Directive, Worker}

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

  defp agent(name, agent \\ %{}, extra \\ %{}) do
    Map.merge(
      %{
        "op" => "serve",
        "label" => name,
        "agent" => Map.merge(%{"purpose" => "Answer questions about the code."}, agent)
      },
      extra
    )
  end

  defp task(label, service, prompt),
    do: %{"op" => "call", "label" => label, "service" => service, "prompt" => prompt}

  defp kill(label),
    do: tick([%{"op" => "kill", "target" => label}], %{"ids" => [label], "timeout_s" => 10})

  defp args_of(id),
    do:
      Path.join([Worker.run_dir(id), "tmp", "fake_claude_args.json"])
      |> File.read!()
      |> Jason.decode!()

  describe "validation" do
    defp check(d), do: Directive.validate([d])

    test "an agent serve is normalised; a prompt call is a task" do
      {[a], []} = check(agent("rev", %{"model" => "haiku", "pool" => "reviewers"}))
      assert a.lang == "agent"

      assert a.agent == %{
               purpose: "Answer questions about the code.",
               model: "haiku",
               tools: ["Read", "Grep", "Glob"],
               pool: "reviewers",
               resume: true,
               memory: "session",
               services: []
             }

      {[], [saved]} = check(agent("rev", %{}, %{"save" => true}))
      assert saved.reason == "save keeps a code service's code; agents can't be saved"

      {[], [r]} = check(agent("rev", %{"leases" => ["docs"]}))
      assert r.reason == ~s(leases go on the serve, next to "agent", not inside it)

      {[s], []} = check(agent("rev", %{"services" => ["db", "search", "db"]}))
      assert s.agent.services == ["db", "search"]

      {[c], []} = check(task("t1", "rev", "look at lib/"))
      assert {c.fn, c.args} == {"task", %{"prompt" => "look at lib/"}}
    end

    test "bad agent directives are rejected with a reason" do
      reasons = fn d -> check(d) |> elem(1) |> Enum.map(& &1.reason) end

      assert reasons.(agent("a", %{"purpose" => " "})) == ["agent purpose is empty"]
      assert reasons.(agent("a", %{"tools" => ["Bash"]})) |> hd() =~ "not allowed"
      assert reasons.(agent("a", %{"tools" => ["Read", "Edit"]})) |> hd() =~ "need leases"

      assert reasons.(agent("a", %{}, %{"code" => "x"})) == [
               "serve takes code or agent, not both"
             ]

      assert reasons.(agent("a", %{}, %{"network" => ["x:1"]})) |> hd() =~ "no network"
      assert reasons.(agent("a", %{"color" => "red"})) |> hd() =~ "color"

      assert reasons.(%{
               "op" => "call",
               "label" => "c",
               "service" => "a",
               "prompt" => "x",
               "fn" => "f"
             }) ==
               ["a call takes prompt (an agent task) or fn/args, not both"]

      {[_], []} = check(agent("a", %{"tools" => ["Read", "Edit"]}, %{"leases" => ["docs"]}))

      assert reasons.(agent("a", %{"services" => "db"})) == [
               "agent services must be a list of service names"
             ]

      assert reasons.(agent("a", %{"services" => ["db", "no spaces"]})) |> hd() =~
               "agent services must be service names"

      many = for i <- 1..17, do: "s#{i}"

      assert reasons.(agent("a", %{"services" => many})) == [
               "an agent may get at most 16 services"
             ]
    end

    test "steer takes a target and text, and can't be waited on" do
      reasons = fn d -> check(d) |> elem(1) |> Enum.map(& &1.reason) end
      steer = %{"op" => "steer", "target" => "rev", "text" => "skip the tests"}

      {[s], []} = check(steer)

      assert s == %{
               op: "steer",
               label: nil,
               target: "rev",
               text: "skip the tests",
               interrupt: false
             }

      {[s], []} = check(Map.put(steer, "interrupt", true))
      assert s.interrupt

      assert reasons.(Map.delete(steer, "text")) == ["steer needs text"]
      assert reasons.(Map.put(steer, "text", "  ")) == ["steer needs text"]
      assert reasons.(Map.delete(steer, "target")) == ["needs a target (#id or label)"]
      assert reasons.(Map.put(steer, "interrupt", "yes")) == ["interrupt must be true or false"]
      assert reasons.(Map.put(steer, "when", "now")) == ["unknown field when"]

      {_, [r]} =
        Directive.validate([
          Map.put(steer, "label", "nudge"),
          %{
            "op" => "run",
            "label" => "r",
            "lang" => "bash",
            "code" => "true",
            "after" => ["nudge"]
          }
        ])

      assert r.reason == "after nudge: steer takes effect at once; wait on its target instead"
    end
  end

  test "an agent serves tasks in one session and shows idle between them" do
    name = uniq("helper")
    first = tick([agent(name, %{"model" => "haiku"}), task("t1-#{name}", name, "hello")])

    assert status(first, name) == "serving"
    assert status(first, "t1-#{name}") == "done"
    assert first.text =~ "done #1: hello"
    assert first.text =~ ~r/agent #{name} · haiku · idle · 1 tasks done · context 3\.0k tokens/

    # Same process, so the second task is message #2.
    second = tick([task("t2-#{name}", name, "again")])
    assert second.text =~ "done #2: again"

    manifest = API.inspect(%{"target" => "manifest"}).text

    assert manifest =~
             "#{name} (##{id_of(first, name)}, agent, idle) · fns: task · agent: Answer questions"

    args = args_of(id_of(first, name))
    assert ["--restricted", "--strict-mcp-config"] -- args == []
    assert Enum.at(args, Enum.find_index(args, &(&1 == "--model")) + 1) == "haiku"
    assert Enum.at(args, Enum.find_index(args, &(&1 == "--tools")) + 1) == "Read,Grep,Glob"

    assert Enum.at(args, Enum.find_index(args, &(&1 == "--system-prompt")) + 1) =~
             ~r/^Answer questions about the code\..*QUESTION:/s

    kill(name)
  end

  test "leases become write rules; .universe is always denied" do
    name = uniq("writer")
    root = Universe.Paths.project_root()

    result =
      tick([
        agent(name, %{"tools" => ["Read", "Edit"]}, %{"leases" => ["docs"]}),
        task("w-#{name}", name, "hi")
      ])

    assert status(result, name) == "serving"
    args = args_of(id_of(result, name))
    settings = Enum.at(args, Enum.find_index(args, &(&1 == "--settings")) + 1) |> Jason.decode!()
    allow = settings["permissions"]["allow"]
    assert "Edit(/#{Path.join(root, "docs")}/**)" in allow
    assert "Read(/#{root}/.universe/**)" in settings["permissions"]["deny"]
    kill(name)
  end

  test "an agent's QUESTION comes back as asking; reply answers it" do
    name = uniq("asker")
    t = "q-#{name}"

    first =
      tick([agent(name), task(t, name, "ASK me")], %{
        "ids" => [t],
        "until" => "any",
        "timeout_s" => 30
      })

    assert status(first, name) == "asking"
    assert first.text =~ "asks: which file?"

    second = tick([%{"op" => "reply", "target" => name, "text" => "lib/a.ex"}], %{"ids" => [t]})
    assert status(second, t) == "done"
    assert second.text =~ "got lib/a.ex"
    kill(name)
  end

  test "a reply aimed at the task reaches the agent that asked" do
    name = uniq("askcall")
    t = "qc-#{name}"

    first =
      tick([agent(name), task(t, name, "ASK me")], %{
        "ids" => [t],
        "until" => "any",
        "timeout_s" => 30
      })

    assert first.text =~ ~r/#{t}\s.*#{name} asks: which file\? · reply to #{t} or #{name}/

    second = tick([%{"op" => "reply", "target" => t, "text" => "lib/b.ex"}], %{"ids" => [t]})
    assert status(second, t) == "done"
    assert second.text =~ "got lib/b.ex"
    kill(name)
  end

  test "tasks for a busy agent wait their turn; the timeout starts when the task does" do
    name = uniq("serial")
    tasks = for i <- 1..3, do: "#{name}-t#{i}"
    tick([agent(name)], %{"ids" => [name], "timeout_s" => 15})

    # Each SLOW task takes 1.5 s; queued behind two others, the third would
    # have used up a 3 s timeout before it started.
    calls = Enum.map(tasks, &Map.put(task(&1, name, "SLOW #{&1}"), "timeout_s", 3))
    first = tick(calls, %{"timeout_s" => 0})
    assert first.text =~ ~r/waits behind 2 tasks on #{name} \(an agent runs one task at a time\)/

    result = tick([], %{"ids" => tasks, "timeout_s" => 30})
    for t <- tasks, do: assert(status(result, t) == "done")
    kill(name)
  end

  test ~s(memory "task" starts each task in a fresh session) do
    [fresh, kept] = [uniq("fresh"), uniq("kept")]

    result =
      tick([
        agent(fresh, %{"memory" => "task"}),
        agent(kept),
        task("a-#{fresh}", fresh, "one"),
        task("a-#{kept}", kept, "one")
      ])

    assert result.text =~ "done #1: one"
    again = tick([task("b-#{fresh}", fresh, "two"), task("b-#{kept}", kept, "two")])
    # The fake claude counts the messages of its session.
    assert again.text =~ ~r/b-#{fresh}.*done #1: two/
    assert again.text =~ ~r/b-#{kept}.*done #2: two/

    # Each task's cost: what the session's cumulative total grew by.
    usage =
      Path.join(Universe.Paths.universe_dir(), "agents/#{kept}.usage.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.map(usage, & &1["cost_usd"]) == [0.01, 0.01]
    kill(fresh)
    kill(kept)
  end

  test "a pool member being killed takes no new task, even in the same tick" do
    pool = uniq("kpool")
    [old, new] = [uniq("old"), uniq("new")]
    tick([agent(old, %{"pool" => pool})], %{"ids" => [old], "timeout_s" => 15})

    t = "#{pool}-t"

    result =
      tick(
        [
          %{"op" => "kill", "target" => old},
          agent(new, %{"pool" => pool}),
          task(t, pool, "hello")
        ],
        %{"ids" => [t], "timeout_s" => 20}
      )

    assert status(result, t) == "done"
    call = Universe.EventLog.for_id(id_of(result, t)) |> Enum.find(&(&1["type"] == "call"))
    assert call["data"]["service"] == new
    kill(new)
  end

  test "while an agent works, a tick comes back early so the model can steer it" do
    Application.put_env(:universe, :helper_wait_s, 2)
    on_exit(fn -> Application.delete_env(:universe, :helper_wait_s) end)
    name = uniq("busy")
    t = "t-#{name}"
    started = System.monotonic_time(:millisecond)
    result = tick([agent(name), task(t, name, "SLEEP")], %{"ids" => [t], "timeout_s" => 30})
    assert System.monotonic_time(:millisecond) - started < 15_000
    assert result.text =~ "back early: helpers still working"
    kill(name)
  end

  test "kill with a pool name stops every member" do
    pool = uniq("kp")
    [a, b] = [uniq("ka"), uniq("kb")]

    tick([agent(a, %{"pool" => pool}), agent(b, %{"pool" => pool})], %{
      "ids" => [a, b],
      "timeout_s" => 15
    })

    result = tick([%{"op" => "kill", "target" => pool}], %{"ids" => [a, b], "timeout_s" => 10})
    assert status(result, a) == "killed"
    assert status(result, b) == "killed"

    none = tick([%{"op" => "kill", "target" => pool}], %{"timeout_s" => 0})
    assert none.text =~ "no worker or agent pool #{pool}"
  end

  test "a pool hands each task to a free agent" do
    pool = uniq("pool")
    [a, b] = [uniq("pa"), uniq("pb")]
    tasks = for i <- 1..4, do: "#{pool}-t#{i}"

    result =
      tick(
        [agent(a, %{"pool" => pool}), agent(b, %{"pool" => pool})] ++
          Enum.map(tasks, &task(&1, pool, "SLOW #{&1}")),
        %{"ids" => tasks, "timeout_s" => 30}
      )

    for t <- tasks, do: assert(status(result, t) == "done")

    served =
      for t <- tasks do
        id = id_of(result, t)
        call = Universe.EventLog.for_id(id) |> Enum.find(&(&1["type"] == "call"))
        assert call["data"]["pool"] == pool
        call["data"]["service"]
      end

    # Two agents, four slow tasks: each agent takes two.
    assert Enum.frequencies(served) == %{a => 2, b => 2}

    unknown = tick([task(uniq("x"), uniq("nopool"), "hi")], %{"timeout_s" => 0})
    assert unknown.text =~ "no live service or agent pool"
    kill(a)
    kill(b)
  end

  test "a crashed claude session fails its task; the next task resumes it" do
    name = uniq("crashy")
    t = "c-#{name}"
    result = tick([agent(name), task(t, name, "CRASH")], %{"ids" => [t], "timeout_s" => 30})

    assert status(result, t) == "failed"
    assert result.text =~ "claude session ended (exit 7); the next task resumes it"

    again =
      tick([task("c2-#{name}", name, "ok now")], %{"ids" => ["c2-#{name}"], "timeout_s" => 30})

    assert status(again, "c2-#{name}") == "done"
    # Same session: the crashed message was #1.
    assert again.text =~ "done #2: ok now"
    kill(name)
  end

  test "serving an agent again resumes its session unless resume is false" do
    name = uniq("keeper")
    tick([agent(name), task("k1-#{name}", name, "first")])
    kill(name)

    back = tick([agent(name), task("k2-#{name}", name, "second")])
    assert back.text =~ "done #2: second"
    assert back.text =~ "resumed its earlier session"
    kill(name)

    fresh = tick([agent(name, %{"resume" => false}), task("k3-#{name}", name, "third")])
    assert fresh.text =~ "done #1: third"
    kill(name)

    # A changed purpose is a different agent: new session.
    other = tick([agent(name, %{"purpose" => "Something else."}), task("k4-#{name}", name, "x")])
    assert other.text =~ "done #1: x"
    kill(name)
  end

  test "a saved session that can't be resumed falls back to a new one" do
    name = uniq("lost")
    tick([agent(name), task("l1-#{name}", name, "first")])
    kill(name)
    File.rm_rf!(Path.join(Universe.Paths.project_root(), ".fake_sessions"))

    back = tick([agent(name), task("l2-#{name}", name, "again")])
    assert status(back, "l2-#{name}") == "done"
    assert back.text =~ "done #1: again"
    assert back.text =~ "saved session lost; new session"
    kill(name)
  end

  test "a lost saved session is replaced at once, even before any task" do
    name = uniq("lostidle")
    tick([agent(name), task("li1-#{name}", name, "first")])
    kill(name)
    File.rm_rf!(Path.join(Universe.Paths.project_root(), ".fake_sessions"))

    back = tick([agent(name)], %{"ids" => [name], "timeout_s" => 15})
    assert back.text =~ ~r/#{name}.*saved session lost; new session/

    next = tick([task("li2-#{name}", name, "again")])
    assert status(next, "li2-#{name}") == "done"
    kill(name)
  end

  test "a task past its timeout is interrupted and the agent is free again" do
    name = uniq("sleepy")
    t = "s-#{name}"
    call = task(t, name, "SLEEP") |> Map.put("timeout_s", 3)
    result = tick([agent(name), call], %{"ids" => [t], "timeout_s" => 30})

    assert status(result, t) == "failed"
    assert result.text =~ "task timed out; the agent stopped it and is idle again"

    next =
      tick([task("s2-#{name}", name, "quick")], %{"ids" => ["s2-#{name}"], "timeout_s" => 10})

    assert status(next, "s2-#{name}") == "done"
    kill(name)
  end
end
