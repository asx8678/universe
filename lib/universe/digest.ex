defmodule Universe.Digest do
  @moduledoc """
  Renders what `tick` returns to the model: one line per worker that changed
  since the last tick, worst news first, under a hard size cap.

      t12 · 4 changed · 1 running · cursor 812
      #7   failed   router-patch  exit 1 · test/router_test.exs:42 assertion failed
      #9   asking   ui-build      Use the new tokens file or the old one?
      #5   done     pg-extract    41s · 1240 rows
      #8   running  dedupe        2m10s · last: scanning 800/1240
      +2 auto-acked (lint, format) · inspect("t12") for all events

  Rows are `%{id, label, status, detail, quiet}`; `id` is nil for rejected
  directives, which never got one. Quiet rows that finished `done` collapse
  into the auto-acked line.
  """

  # ~2,000 tokens at the chars/4 estimate used everywhere in Universe.
  @max_chars 8_000
  @detail_max 160
  # Small run outputs shown in full under their row, at most this much a tick.
  @output_max 4_500

  @order ~w(failed budget rejected asking killed done running queued)

  @doc "Token estimate used for budgets and the observer (chars / 4)."
  def estimate_tokens(text), do: div(String.length(text) + 3, 4)

  def max_chars, do: @max_chars

  @doc """
  Builds the digest text. `info` has `:tick`, `:rows`, `:running`, `:queued`,
  `:cursor` and `:wake` (`"settled" | "attention" | "timeout" | "now"`).
  """
  def build(info) do
    {acked, rows} = Enum.split_with(info.rows, &(&1[:quiet] && &1.status == "done"))
    {restarted, rows} = Enum.split_with(rows, &restart_kill?/1)
    {alike, rows} = alike_done(rows)
    rows = Enum.sort_by(rows, &{rank(&1.status), &1.id || 0})

    header = header(info, length(info.rows))
    width = rows |> Enum.map(&String.length(&1.label || "")) |> Enum.max(fn -> 0 end) |> min(24)
    footer = footer(info.tick, acked)

    rows_lines =
      with_outputs(rows, width) ++
        Enum.map(alike, &alike_line/1) ++ restarted_line(restarted)

    {lines, dropped} =
      fit(rows_lines, String.length(header) + String.length(footer) + 2)

    overflow =
      if dropped > 0,
        do: [
          "+#{dropped} more line#{if dropped == 1, do: "", else: "s"} · inspect(\"t#{info.tick}\")"
        ],
        else: []

    Enum.join([header] ++ lines ++ overflow ++ [footer], "\n")
  end

  defp header(info, changed) do
    parts =
      ["t#{info.tick}", "#{changed} changed"] ++
        count(info.running, "running") ++
        count(info.queued, "queued") ++
        ["cursor #{info.cursor}"] ++
        if(info.wake == "timeout", do: ["woke on timeout"], else: [])

    Enum.join(parts, " · ")
  end

  # Workers that only ended because the daemon stopped or restarted fold
  # into one line: one per worker after every restart says nothing new.
  @restart_reasons ["Universe shut down", "lost: Universe restarted"]

  defp restart_kill?(row),
    do:
      row.status == "killed" and
        Enum.any?(@restart_reasons, &String.starts_with?(row[:detail] || "", &1))

  # @alike_min or more workers that finished `done` with the same detail
  # (typically just a duration) say one thing: fold them into one line.
  @alike_min 5

  defp alike_done(rows) do
    groups =
      rows
      |> Enum.filter(&(&1.status == "done" and &1.id != nil and &1[:output] == nil))
      |> Enum.group_by(&(&1[:detail] || ""))
      |> Enum.filter(fn {_detail, rs} -> length(rs) >= @alike_min end)

    folded = groups |> Enum.flat_map(&elem(&1, 1)) |> MapSet.new(& &1.id)

    {Enum.map(groups, fn {detail, rs} -> {detail, Enum.sort_by(rs, & &1.id)} end),
     Enum.reject(rows, &MapSet.member?(folded, &1.id))}
  end

  defp alike_line({detail, rows}) do
    ids = Enum.map(rows, & &1.id)
    labels = Enum.map(rows, & &1.label)

    range =
      if ids == Enum.to_list(List.first(ids)..List.last(ids)),
        do: "##{List.first(ids)}–##{List.last(ids)}: ",
        else: ""

    names =
      if length(labels) > 4,
        do: Enum.join(Enum.take(labels, 3), ", ") <> ", …, " <> List.last(labels),
        else: Enum.join(labels, ", ")

    detail = if detail == "", do: "", else: " · #{detail}"
    "+#{length(rows)} done#{detail} (#{range}#{names})"
  end

  defp restarted_line([]), do: []

  defp restarted_line(rows) do
    names = rows |> Enum.map(&"##{&1.id} #{&1.label}") |> Enum.take(6) |> Enum.join(", ")
    more = if length(rows) > 6, do: ", …", else: ""
    ["+#{length(rows)} stopped when Universe restarted (#{names}#{more})"]
  end

  defp count(0, _what), do: []
  defp count(n, what), do: ["#{n} #{what}"]

  defp footer(tick, []), do: "inspect(\"t#{tick}\") for all events"

  defp footer(tick, acked) do
    names = acked |> Enum.map(& &1.label) |> Enum.take(6) |> Enum.join(", ")
    more = if length(acked) > 6, do: ", …", else: ""
    "+#{length(acked)} auto-acked (#{names}#{more}) · inspect(\"t#{tick}\") for all events"
  end

  # Each row's line, plus its run output (indented) while the tick's output
  # budget lasts; the first rows (worst news first) get it.
  defp with_outputs(rows, width) do
    {lines, _left} =
      Enum.map_reduce(rows, @output_max, fn row, left ->
        out = row[:output]
        size = if out, do: Enum.reduce(out, 0, &(String.length(&1) + 5 + &2)), else: 0

        if out && size <= left,
          do: {Enum.join([line(row, width) | Enum.map(out, &("    " <> &1))], "\n"), left - size},
          else: {line(row, width), left}
      end)

    lines
  end

  defp line(row, width) do
    id = if row.id, do: "##{row.id}", else: "--"
    label = (row.label || "-") |> String.slice(0, 24) |> String.pad_trailing(width)
    detail = clip(row[:detail] || "")

    [String.pad_trailing(id, 4), String.pad_trailing(row.status, 8), label, detail]
    |> Enum.join(" ")
    |> String.trim_trailing()
  end

  # Keeps whole lines, in order, until the cap; reports how many didn't fit.
  defp fit(lines, reserved) do
    {kept, _used} =
      Enum.reduce_while(lines, {[], reserved}, fn line, {acc, used} ->
        size = String.length(line) + 1
        # Leave room for the overflow pointer itself.
        if used + size + 40 <= @max_chars,
          do: {:cont, {[line | acc], used + size}},
          else: {:halt, {acc, used}}
      end)

    {Enum.reverse(kept), length(lines) - length(kept)}
  end

  defp rank(status), do: Enum.find_index(@order, &(&1 == status)) || length(@order)

  defp clip(text) do
    text = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(text) > @detail_max,
      do: String.slice(text, 0, @detail_max - 1) <> "…",
      else: text
  end

  @doc "Formats milliseconds as 41s or 2m10s."
  def duration(nil), do: ""
  def duration(ms) when ms < 1_000, do: "#{ms}ms"
  def duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"

  def duration(ms) do
    s = div(ms, 1000)
    "#{div(s, 60)}m#{String.pad_leading(Integer.to_string(rem(s, 60)), 2, "0")}s"
  end
end
