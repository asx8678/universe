defmodule Universe.DirectiveTest do
  use ExUnit.Case, async: true

  alias Universe.Directive

  defp run(label, extra \\ %{}),
    do: Map.merge(%{"op" => "run", "label" => label, "lang" => "bash", "code" => "true"}, extra)

  defp reasons({_ok, rejected}), do: Map.new(rejected, &{&1.label, &1.reason})
  defp labels({ok, _rejected}), do: Enum.map(ok, & &1.label)

  test "normalises a valid run with defaults" do
    assert {[d], []} = Directive.validate([run("a")])

    assert d == %{
             op: "run",
             label: "a",
             lang: "bash",
             code: "true",
             budget: %{wall_s: 120, out_kb: 256, mem_mb: 2048},
             leases: [],
             after: [],
             then: [],
             quiet: false
           }
  end

  test "rejects bad shapes with reasons instead of raising" do
    result =
      Directive.validate([
        %{"op" => "frob", "label" => "u"},
        run("f", %{"extra" => 1}),
        %{"op" => "run", "label" => "nc", "lang" => "bash"},
        run("lang", %{"lang" => "ruby"}),
        %{"op" => "serve", "label" => "svc"},
        run("big", %{"budget" => %{"wall_s" => 99_999}}),
        %{"op" => "kill"},
        "not a map"
      ])

    assert labels(result) == []
    r = reasons(result)
    assert r["u"] =~ "unknown op"
    assert r["f"] =~ "unknown field extra"
    assert r["nc"] =~ "missing code"
    assert r["lang"] =~ "unknown lang"
    assert r["svc"] =~ "missing lang"
    assert r["big"] =~ "budget.wall_s"
    assert r[nil] in ["kill needs a target (#id or label)", "directive must be an object"]
  end

  test "a non-list or oversized batch is one rejection" do
    assert {[], [%{reason: "directives must be a list"}]} = Directive.validate("x")

    assert {[], [%{reason: "at most 64" <> _}]} =
             Directive.validate(Enum.map(1..65, &run("r#{&1}")))

    assert {[], []} = Directive.validate(nil)
  end

  test "labels must be unique across the batch, then steps included" do
    result = Directive.validate([run("a"), run("b", %{"then" => [run("a")]}), run("c")])
    assert labels(result) == ["c"]
    assert result |> elem(1) |> Enum.all?(&(&1.reason == "duplicate label a"))
  end

  test "after resolves batch labels and known references, nothing else" do
    resolve = fn
      "old" -> {:ok, 3}
      "#3" -> {:ok, 3}
      _ -> :error
    end

    result =
      Directive.validate(
        [
          run("a", %{"after" => ["b"]}),
          run("b"),
          run("c", %{"after" => ["old", "#3"]}),
          run("d", %{"after" => ["nope"]}),
          run("e", %{"after" => ["#99"]})
        ],
        resolve
      )

    assert labels(result) == ["a", "b", "c"]
    r = reasons(result)
    assert r["d"] == "after nope: unknown label"
    assert r["e"] == "after #99: no such worker"
  end

  test "after cycles are rejected, including self-references" do
    result =
      Directive.validate([
        run("a", %{"after" => ["b"]}),
        run("b", %{"after" => ["a"]}),
        run("self", %{"after" => ["self"]}),
        run("ok")
      ])

    assert labels(result) == ["ok"]
    assert reasons(result)["a"] =~ "cycle"
    assert reasons(result)["self"] =~ "cycle"
  end

  test "a long dependency DAG validates fast; a cycle in it is found" do
    dag =
      for i <- 0..63 do
        deps = for j <- [i - 1, i - 2], j >= 0, do: "d#{j}"
        run("d#{i}", %{"after" => deps})
      end

    {us, result} = :timer.tc(fn -> Directive.validate(dag) end)
    assert length(labels(result)) == 64
    assert us < 500_000

    # Closing the chain into a loop rejects its members, and only those.
    looped = dag |> Enum.take(40) |> List.update_at(0, &Map.put(&1, "after", ["d39"]))
    {ok, rejected} = Directive.validate(looped ++ [run("free")])
    assert Enum.map(ok, & &1.label) == ["free"]
    assert Enum.all?(rejected, &(&1.reason =~ "cycle involving"))
  end

  test "a malformed wait comes back as rejections and a clean wait" do
    assert {nil, []} = Directive.validate_wait(nil)

    assert {%{"ids" => ["#5", "kv"], "until" => "any"}, []} =
             Directive.validate_wait(%{"ids" => [5, "kv"], "until" => "any"})

    {wait, rejected} =
      Directive.validate_wait(%{
        "ids" => [%{"a" => 1}, "ok"],
        "until" => "some",
        "timeout_s" => "10",
        "x" => 1
      })

    assert wait == %{"ids" => ["ok"]}
    assert length(rejected) == 4
    assert {nil, [%{op: "wait"}]} = Directive.validate_wait("x")
    assert {%{}, [_]} = Directive.validate_wait(%{"ids" => "x"})
  end

  test "anything depending on a rejected directive is rejected, transitively" do
    result =
      Directive.validate([
        run("bad", %{"lang" => "cobol"}),
        run("mid", %{"after" => ["bad"]}),
        run("leaf", %{"after" => ["mid"]}),
        run("free")
      ])

    assert labels(result) == ["free"]
    assert reasons(result)["mid"] == "depends on rejected bad"
    assert reasons(result)["leaf"] == "depends on rejected mid"
  end

  test "then steps are runs without after, and can't be waited on" do
    result =
      Directive.validate([
        run("p", %{"then" => [run("t1", %{"after" => ["x"]})]}),
        run("q", %{"then" => [run("t2")]}),
        run("r", %{"after" => ["t2"]})
      ])

    assert labels(result) == ["q"]
    assert reasons(result)["p"] =~ "then steps can't have after"
    assert reasons(result)["r"] =~ "then steps can't be waited on"
  end

  test "leases are project-relative and stay out of .universe" do
    result =
      Directive.validate([
        run("abs", %{"leases" => ["/etc"]}),
        run("up", %{"leases" => ["../x"]}),
        run("u", %{"leases" => [".universe/token"]}),
        run("glob", %{"leases" => ["src/*.ex"]}),
        run("ok", %{"leases" => ["src/", "./lib/a.ex"]})
      ])

    assert {[ok], _} = result
    assert ok.leases == ["src", "lib/a.ex"]
    r = reasons(result)
    assert r["abs"] =~ "relative"
    assert r["up"] =~ ".."
    assert r["u"] =~ "off limits"
    assert r["glob"] =~ "globs"
  end

  test "after can't wait on a kill or reply (they have no worker to settle)" do
    result =
      Directive.validate([
        %{"op" => "run", "label" => "k", "lang" => "bash", "code" => "sleep 1"},
        %{"op" => "kill", "label" => "stop", "target" => "k"},
        %{
          "op" => "run",
          "label" => "next",
          "lang" => "bash",
          "code" => "echo hi",
          "after" => ["stop"]
        }
      ])

    assert {ok, rejected} = result
    assert "next" not in Enum.map(ok, & &1.label)
    reason = Enum.find_value(rejected, &(&1.label == "next" && &1.reason))
    assert reason =~ "kill takes effect at once"
  end

  test "parse_id/1" do
    assert Directive.parse_id("#12") == {:ok, 12}
    assert Directive.parse_id("12") == :error
    assert Directive.parse_id("#x") == :error
  end
end
