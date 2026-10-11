defmodule Universe.TickTest do
  # Drives the application's single Tick server.
  use ExUnit.Case, async: false

  alias Universe.{API, Tick}

  defp run(label, code, extra \\ %{}),
    do: Map.merge(%{"op" => "run", "label" => label, "lang" => "bash", "code" => code}, extra)

  # Labels are global across ticks; keep each test's unique.
  defp uniq(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp tick(directives, wait \\ nil) do
    args = %{"directives" => directives}
    API.tick(if wait, do: Map.put(args, "wait", wait), else: args)
  end

  defp status_of(result, label) do
    Enum.find_value(result.structured["ids"], fn {_, v} -> v["label"] == label && v["status"] end)
  end

  test "independent runs execute in parallel in one tick" do
    labels = for i <- 1..5, do: uniq("par#{i}")
    started = System.monotonic_time(:millisecond)
    result = tick(Enum.map(labels, &run(&1, "sleep 1; echo done")))
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 2_000
    assert result.structured["wake"] == "settled"
    for l <- labels, do: assert(status_of(result, l) == "done")
    assert result.text =~ ~r/^t\d+ · 5 changed/
  end

  test "then steps run on success without waking the model; skipped on failure" do
    [p, c, bad, never] = Enum.map(~w(p c bad never), &uniq/1)

    result =
      tick([
        run(p, "echo parent", %{"then" => [run(c, "echo child")]}),
        run(bad, "exit 2", %{"then" => [run(never, "echo nope")]})
      ])

    assert status_of(result, p) == "done"
    assert status_of(result, c) == "done"
    assert status_of(result, bad) == "failed"
    refute status_of(result, never)
    assert result.text =~ "then skipped: #{never}"
  end

  test "after waits for dependencies and fails when one fails" do
    [a, b, x, y] = Enum.map(~w(a b x y), &uniq/1)

    result =
      tick([
        run(b, "cat /tmp/$$ 2>/dev/null; echo b-ran", %{"after" => [a]}),
        run(a, "sleep 0.3; echo a-ran"),
        run(x, "exit 1"),
        run(y, "echo should-not-run", %{"after" => [x]})
      ])

    assert status_of(result, a) == "done"
    assert status_of(result, b) == "done"
    assert status_of(result, y) == "failed"
    assert result.text =~ ~r/#{y}\s+dep #\d+ failed/
  end

  test "after can name a label from an earlier tick" do
    first = uniq("first")
    tick([run(first, "echo one")])
    second = uniq("second")
    assert status_of(tick([run(second, "echo two", %{"after" => [first]})]), second) == "done"
  end

  test "bad directives become rejected lines, not errors" do
    good = uniq("good")
    result = tick([run(good, "true"), %{"op" => "explode", "label" => "boom"}])

    assert status_of(result, good) == "done"
    assert result.text =~ ~r/--\s+rejected boom\s+unknown op "explode"/
    assert [%{"label" => "boom"}] = result.structured["rejected"]
  end

  test "timeout wakes with running workers reported" do
    slow = uniq("slow")
    result = tick([run(slow, "echo working; sleep 5")], %{"timeout_s" => 1})

    assert result.structured["wake"] == "timeout"
    assert status_of(result, slow) == "running"
    assert result.text =~ "woke on timeout"
    tick([%{"op" => "kill", "target" => slow}], %{"timeout_s" => 5})
  end

  test "until any returns on the first settled ID" do
    [fast, slow] = Enum.map(~w(fast slow), &uniq/1)

    result =
      tick([run(fast, "true"), run(slow, "sleep 5")], %{"until" => "any", "timeout_s" => 10})

    assert result.structured["wake"] == "settled"
    assert status_of(result, fast) == "done"
    tick([%{"op" => "kill", "target" => slow}], %{"timeout_s" => 5})
  end

  test "an unreported failure wakes the model early (attention)" do
    [fails, slow] = Enum.map(~w(fails slow), &uniq/1)
    result = tick([run(fails, "exit 1"), run(slow, "sleep 10")], %{"timeout_s" => 8})

    assert result.structured["wake"] == "attention"
    assert status_of(result, fails) == "failed"
    tick([%{"op" => "kill", "target" => slow}], %{"timeout_s" => 5})
  end

  test "kill stops a running worker; killing a settled one is rejected" do
    victim = uniq("victim")
    tick([run(victim, "sleep 30")], %{"timeout_s" => 0})

    result =
      tick([%{"op" => "kill", "target" => victim}], %{"ids" => [victim], "timeout_s" => 10})

    assert status_of(result, victim) == "killed"

    again = tick([%{"op" => "kill", "target" => victim}], %{"timeout_s" => 0})
    assert again.text =~ "is already killed"
  end

  test "overlapping leases are rejected and name the holder" do
    [holder, rival] = Enum.map(~w(holder rival), &uniq/1)
    tick([run(holder, "sleep 3", %{"leases" => ["leasetest"]})], %{"timeout_s" => 0})
    result = tick([run(rival, "true", %{"leases" => ["leasetest/sub"]})], %{"timeout_s" => 0})

    assert result.text =~ ~r/rejected #{rival}\s+lease leasetest\/sub held by #\d+/
    tick([%{"op" => "kill", "target" => holder}], %{"timeout_s" => 5})
  end

  test "a clashing lease waits when the directive waits anyway (after)" do
    [holder, waiter] = Enum.map(~w(lholder lwaiter), &uniq/1)

    tick(
      [
        run(holder, "mkdir -p leasewait && sleep 1 && echo a > leasewait/a", %{
          "leases" => ["leasewait"]
        })
      ],
      %{"timeout_s" => 0}
    )

    queued =
      tick(
        [run(waiter, "echo b > leasewait/b", %{"leases" => ["leasewait"], "after" => [holder]})],
        %{"timeout_s" => 0}
      )

    refute queued.text =~ "rejected"

    result = tick([], %{"ids" => [waiter], "timeout_s" => 15})
    assert status_of(result, waiter) == "done"
  end

  test "a blocked connection is explained, not left as a DNS error" do
    net = uniq("net")

    code =
      "import urllib.request; urllib.request.urlopen('https://example.com', timeout=5)"

    result = tick([run(net, code, %{"lang" => "python"})], %{"ids" => [net], "timeout_s" => 20})
    assert status_of(result, net) == "failed"
    assert result.text =~ "network is blocked for this worker"
  end

  test "two queued workers that need one lease don't deadlock" do
    [z, a, b] = Enum.map(~w(lz la lb), &uniq/1)

    result =
      tick(
        [
          run(z, "sleep 0.3"),
          run(a, "mkdir -p dl && echo a >> dl/log", %{"leases" => ["dl"], "after" => [b]}),
          run(b, "mkdir -p dl && echo b >> dl/log", %{"leases" => ["dl"], "after" => [z]})
        ],
        %{"ids" => [a, b], "timeout_s" => 20}
      )

    assert status_of(result, a) == "done"
    assert status_of(result, b) == "done"
  end

  test "a malformed wait is rejected and the kernel keeps running" do
    live = uniq("alive")
    tick([run(live, "sleep 30")], %{"timeout_s" => 0})
    kernel = Process.whereis(Universe.Tick)

    for wait <- [%{"ids" => [%{"a" => 1}]}, "x", %{"ids" => "x"}, %{"timeout_s" => "10"}] do
      {us, result} = :timer.tc(fn -> API.tick(%{"directives" => [], "wait" => wait}) end)
      assert result.text =~ "rejected"
      assert us < 2_000_000
    end

    # Same kernel process, and it still tracks the running worker.
    assert Process.whereis(Universe.Tick) == kernel

    assert Enum.any?(
             Map.values(Universe.Tick.snapshot()),
             &(&1.label == live and &1.status == "running")
           )

    tick([%{"op" => "kill", "target" => live}], %{"timeout_s" => 5})
  end

  test "an empty tick reports changes since the cursor, then nothing" do
    noisy = uniq("noisy")
    tick([run(noisy, "true")])
    assert tick([], %{"timeout_s" => 0}).text =~ ~r/^t\d+ · 0 changed/

    replay = API.tick(%{"directives" => [], "since" => 0, "wait" => %{"timeout_s" => 0}})
    assert replay.text =~ noisy or replay.text =~ "more line"
  end

  test "stop_all kills queued and running workers" do
    [a, b] = Enum.map(~w(sa sb), &uniq/1)
    tick([run(a, "sleep 30"), run(b, "echo", %{"after" => [a]})], %{"timeout_s" => 0})
    assert {:ok, n} = Tick.stop_all()
    assert n >= 2

    result = tick([], %{"ids" => [a, b], "timeout_s" => 10})
    assert status_of(result, a) == "killed"
    assert status_of(result, b) == "killed"
  end

  test "unknown wait ids are reported instead of silently ignored" do
    result = tick([], %{"ids" => ["no-such-label"], "timeout_s" => 0})
    assert result.text =~ ~r/rejected no-such-label\s+wait: no worker no-such-label/
  end

  test "tick_in and tick_out are logged with token estimates" do
    label = uniq("logged")
    result = tick([run(label, "true")])
    events = Universe.EventLog.for_tick(result.structured["tick"])
    types = Enum.map(events, & &1["type"])

    assert hd(types) == "tick_in"
    assert List.last(types) == "tick_out"
    out = List.last(events)["data"]
    assert out["text"] == result.text
    assert out["tokens_out_est"] > 0 and out["tokens_in_est"] > 0
  end
end
