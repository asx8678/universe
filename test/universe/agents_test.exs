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
               pool: "reviewers"
             }

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

  test "a crashed claude session fails its task; the next task gets a fresh session" do
    name = uniq("crashy")
    t = "c-#{name}"
    result = tick([agent(name), task(t, name, "CRASH")], %{"ids" => [t], "timeout_s" => 30})

    assert status(result, t) == "failed"
    assert result.text =~ "claude session ended (exit 7)"

    again =
      tick([task("c2-#{name}", name, "ok now")], %{"ids" => ["c2-#{name}"], "timeout_s" => 30})

    assert status(again, "c2-#{name}") == "done"
    assert again.text =~ "done #1: ok now"
    kill(name)
  end
end
