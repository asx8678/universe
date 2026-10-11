defmodule Universe.DigestTest do
  use ExUnit.Case, async: true

  alias Universe.Digest

  defp info(rows, extra \\ %{}),
    do:
      Map.merge(
        %{tick: 12, rows: rows, running: 0, queued: 0, cursor: 812, wake: "settled"},
        extra
      )

  test "renders the documented shape (golden)" do
    rows = [
      %{id: 8, label: "dedupe", status: "running", detail: "2m10s · last: scanning 800/1240"},
      %{id: 5, label: "pg-extract", status: "done", detail: "41s · 1240 rows"},
      %{
        id: 9,
        label: "ui-build",
        status: "asking",
        detail: "Use the new tokens file or the old one?"
      },
      %{
        id: 7,
        label: "router-patch",
        status: "failed",
        detail: "exit 1 · test/router_test.exs:42 assertion failed"
      },
      %{id: 10, label: "lint", status: "done", detail: "1s", quiet: true},
      %{id: 11, label: "format", status: "done", detail: "1s", quiet: true}
    ]

    assert Digest.build(info(rows, %{running: 1})) == """
           t12 · 6 changed · 1 running · cursor 812
           #7   failed   router-patch exit 1 · test/router_test.exs:42 assertion failed
           #9   asking   ui-build     Use the new tokens file or the old one?
           #5   done     pg-extract   41s · 1240 rows
           #8   running  dedupe       2m10s · last: scanning 800/1240
           +2 auto-acked (lint, format) · inspect("t12") for all events\
           """
  end

  test "orders failed, budget, rejected, asking, killed, done, running, queued" do
    statuses = ~w(queued running done killed asking rejected budget failed)

    rows =
      statuses
      |> Enum.with_index(1)
      |> Enum.map(fn {s, i} -> %{id: i, label: s, status: s, detail: ""} end)

    [_header | lines] = rows |> info() |> Digest.build() |> String.split("\n") |> Enum.drop(-1)

    assert Enum.map(lines, &(&1 |> String.split() |> Enum.at(1))) ==
             ~w(failed budget rejected asking killed done running queued)
  end

  test "workers stopped by a restart fold into one line" do
    rows = [
      %{id: 3, label: "kv", status: "killed", detail: "Universe shut down"},
      %{id: 4, label: "job", status: "killed", detail: "lost: Universe restarted"},
      %{id: 5, label: "victim", status: "killed", detail: "stopped by stop all"}
    ]

    text = Digest.build(info(rows))
    assert text =~ "+2 stopped when Universe restarted (#3 kv, #4 job)"
    assert text =~ ~r/#5\s+killed\s+victim/
    refute text =~ ~r/#3\s+killed/
  end

  test "many workers done alike fold into one line; different ones stay" do
    alike = for i <- 0..19, do: %{id: 152 + i, label: "job-#{i}", status: "done", detail: "3s"}
    other = %{id: 200, label: "report", status: "done", detail: "3s · 42 rows"}
    text = Digest.build(info(alike ++ [other]))

    assert text =~ "+20 done · 3s (#152–#171: job-0, job-1, job-2, …, job-19)"
    assert text =~ ~r/#200\s+done\s+report\s+3s · 42 rows/
    refute text =~ ~r/#153\s+done/
  end

  test "rejected rows have no ID" do
    text =
      Digest.build(info([%{id: nil, label: "bad", status: "rejected", detail: "unknown op"}]))

    assert text =~ "--   rejected bad unknown op"
  end

  test "stays under the cap and points at inspect when it overflows" do
    rows =
      for i <- 1..300,
          do: %{id: i, label: "worker-#{i}", status: "failed", detail: String.duplicate("x", 150)}

    text = Digest.build(info(rows))

    assert String.length(text) <= Digest.max_chars()
    assert Digest.estimate_tokens(text) <= 2_000
    assert text =~ ~r/\+\d+ more lines · inspect\("t12"\)/
    assert text =~ "#1 "
  end

  test "long details are clipped to one line" do
    text =
      Digest.build(
        info([
          %{
            id: 1,
            label: "a",
            status: "done",
            detail: "line one\nline two " <> String.duplicate("y", 400)
          }
        ])
      )

    [_, line, _] = String.split(text, "\n")
    assert String.length(line) < 200
    assert line =~ "line one line two"
  end

  test "header shows running, queued and a timeout wake" do
    text = Digest.build(info([], %{running: 2, queued: 3, wake: "timeout"}))
    assert text =~ "t12 · 0 changed · 2 running · 3 queued · cursor 812 · woke on timeout"
  end

  test "duration/1" do
    assert Digest.duration(420) == "420ms"
    assert Digest.duration(41_000) == "41s"
    assert Digest.duration(130_000) == "2m10s"
    assert Digest.duration(nil) == ""
  end
end
