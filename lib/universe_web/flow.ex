defmodule UniverseWeb.Flow do
  @moduledoc """
  Builds a sequence diagram of one tick: who sent what to whom, in order.

  A tick's window is every event from its `tick_in` up to the next tick's
  `tick_in` (or the end of the log): what the model asked for, everything
  that happened because of it, and whatever else ran until the model's next
  tick (replies, calls into older services, late output).

  Lanes, left to right: the model, Universe (the kernel), one lane per worker
  in order of appearance (runs, services, agents), and the handle store.
  Rows are either messages (`from` → `to`) or notes on one lane. Repeated
  output and progress on a lane fold into one note until that lane sends or
  receives a message.

  Pure over events; `diagram/2` takes lookups so tests can pass their own.
  """

  alias Universe.{Digest, EventLog}
  alias UniverseWeb.Activity

  @max_rows 400

  @type lane :: %{key: String.t(), label: String.t(), sub: String.t(), kind: atom()}
  @type row ::
          %{
            type: :msg,
            from: String.t(),
            to: String.t(),
            label: String.t(),
            tone: atom(),
            dashed: boolean(),
            at: String.t(),
            seq: integer()
          }
          | %{
              type: :note,
              lane: String.t(),
              label: String.t(),
              tone: atom(),
              count: integer(),
              at: String.t(),
              seq: integer(),
              fold: atom() | nil
            }
          | %{type: :divider, label: String.t(), at: String.t(), seq: integer()}

  @doc """
  The events of tick `n`'s window, or `nil` if there is no such tick. Also
  returns whether the window is still open (no later tick yet).
  """
  def window(n) do
    ticks = EventLog.by_types(["tick_in"])

    case Enum.find_index(ticks, &(&1["tick"] == n)) do
      nil ->
        nil

      i ->
        from = Enum.at(ticks, i)["seq"]
        next = Enum.at(ticks, i + 1)
        events = EventLog.between(from, next && next["seq"])

        %{
          events: events,
          open: is_nil(next),
          prev: prev_tick(ticks, i),
          next: next && next["tick"]
        }
    end
  end

  defp prev_tick(_ticks, 0), do: nil
  defp prev_tick(ticks, i), do: Enum.at(ticks, i - 1)["tick"]

  @doc """
  Lanes and rows for `events`. Options:

    * `:worker` - `fn id -> %{label: String.t(), kind: String.t(), lang: String.t() | nil}`
    * `:owner` - `fn service_name, seq -> worker_id | nil` (who served it then)
  """
  def diagram(events, opts \\ []) do
    worker = Keyword.get(opts, :worker, &worker_info/1)
    owner = Keyword.get_lazy(opts, :owner, &owner_lookup/0)

    acc = %{
      rows: [],
      lanes: %{},
      order: [],
      open: %{},
      info: %{},
      calls: %{},
      after_digest: false
    }

    acc =
      Enum.reduce(events, acc, fn e, acc ->
        if length(acc.rows) >= @max_rows, do: acc, else: step(e, acc, worker, owner)
      end)

    rows = Enum.reverse(acc.rows)
    folded = rows |> Enum.filter(&(&1.type == :note)) |> Enum.map(&(&1.count - 1)) |> Enum.sum()

    rows =
      if length(acc.rows) >= @max_rows,
        do:
          rows ++
            [
              %{
                type: :divider,
                label: "row limit reached; inspect the tick for the rest",
                at: "",
                seq: -1
              }
            ],
        else: rows

    %{lanes: lanes(acc), rows: rows, events: length(events), folded: folded}
  end

  ## Events → rows

  defp step(%{"type" => type} = e, acc, worker, owner) do
    d = e["data"] || %{}
    id = e["id"]
    acc = remember(acc, e, worker)

    case type do
      "tick_in" ->
        msg(acc, e, "model", "universe", "tick t#{e["tick"]}: " <> directives_text(d), :model)

      "tick_out" ->
        acc
        |> msg(
          e,
          "universe",
          "model",
          "digest · #{d["wake"]} · ~#{d["tokens_out_est"]} tokens",
          :model,
          true
        )
        |> Map.put(:after_digest, true)
        |> divider(e, "digest returned · later events reach the model in its next tick")

      "rejected" ->
        note(acc, e, "universe", "rejected #{d["label"] || d["op"]}: #{d["reason"]}", :bad)

      "spawn" ->
        what =
          if d["lang"] == "agent", do: "start agent", else: "start #{d["kind"]} (#{d["lang"]})"

        msg(acc, e, "universe", w(id), what, :info)

      "serve" ->
        msg(acc, e, w(id), "universe", "serving #{d["name"]}", :good)

      "call" ->
        call(acc, e, d, owner)

      "call_done" ->
        target = service_lane(d["service"], e["seq"], owner)

        label =
          if d["ok"], do: "answer · #{dur(d["wall_ms"])}", else: "failed · #{dur(d["wall_ms"])}"

        msg(acc, e, target, w(id), label, if(d["ok"], do: :good, else: :bad), true)

      "exit" ->
        exit_row(acc, e, d)

      "put" ->
        from = if Map.has_key?(acc.calls, id), do: "universe", else: w(id)
        msg(acc, e, from, "handles", "store #{d["handle"]} (#{d["summary"]})", :info)

      "get" ->
        msg(acc, e, "handles", w(id), "read #{d["handle"]}", :info, true)

      "ask" ->
        msg(acc, e, w(id), "model", "asks: #{d["question"]}", :warn)

      "reply" ->
        msg(acc, e, "model", w(id), "reply: #{d["text"]}", :model)

      # An agent's busy/idle progress and per-task log lines repeat what its
      # task and answer arrows already show.
      t when t in ["progress", "stdout"] and is_integer(id) ->
        if agent?(acc, id),
          do: acc,
          else: fold(acc, e, w(id), String.to_atom(t), progress_or_output(t, d), :muted)

      "stderr" ->
        fold(acc, e, w(id), :stderr, output_line(d), :bad)

      "restart" ->
        note(acc, e, w(id), "restarting (attempt #{d["attempt"]})", :warn)

      "budget_hit" ->
        note(acc, e, w(id), "#{d["budget"]} budget hit", :bad)

      "redirect" ->
        note(acc, e, "model", "Bash redirected: #{d["command"]}", :warn)

      "stop_all" ->
        note(acc, e, "universe", "stop all", :warn)

      "gc" when is_integer(id) ->
        note(acc, e, w(id), "gc: #{d["action"]}", :muted)

      _ ->
        acc
    end
  end

  defp call(acc, e, d, owner) do
    target = service_lane(d["service"], e["seq"], owner)

    label =
      case d["prompt"] do
        p when is_binary(p) -> "task: #{p}"
        _ -> "call #{d["fn"]}"
      end

    if d["via"] == "sdk" do
      msg(acc, e, w(e["id"]), target, label, :info)
    else
      # A call directive: Universe calls the service for the model. The call's
      # own ID is not a lane; remember where its answer comes from.
      acc = put_in(acc.calls[e["id"]], target)
      pool = if d["pool"], do: " (pool #{d["pool"]})", else: ""
      msg(acc, e, "universe", target, label <> pool, :info)
    end
  end

  defp exit_row(acc, e, d) do
    id = e["id"]
    tone = exit_tone(d["status"])

    case acc.calls do
      %{^id => service} ->
        label =
          case d do
            %{"status" => "done", "handle" => h} -> "answer → #{h}"
            %{"status" => "done", "result_text" => t} -> "answer: #{Activity.result_text(t)}"
            _ -> "#{d["status"]}: #{d["reason"]}"
          end

        msg(acc, e, service, "universe", label, tone, true)

      _ ->
        if call_id?(acc, id) do
          # A call from before this window: its target is unknown here.
          note(acc, e, "universe", "call ##{id} #{d["status"]}", tone)
        else
          detail = d["reason"] || d["last_err"] || d["last_out"]

          label =
            Enum.join(
              Enum.filter(["exit #{d["status"]}", dur(d["wall_ms"]), detail], & &1),
              " · "
            )

          msg(acc, e, w(id), "universe", label, tone, true)
        end
    end
  end

  defp call_id?(acc, id), do: match?(%{kind: "call"}, acc.info[id])
  defp agent?(acc, id), do: match?(%{lang: "agent"}, acc.info[id])

  defp progress_or_output("progress", d), do: d["text"]
  defp progress_or_output("stdout", d), do: output_line(d)

  ## Rows

  defp msg(acc, e, from, to, label, tone, dashed \\ false) do
    acc = acc |> lane(from) |> lane(to) |> close(from) |> close(to)

    row = %{
      type: :msg,
      from: from,
      to: to,
      label: clip(label),
      tone: tone,
      dashed: dashed,
      at: at(e),
      seq: e["seq"]
    }

    %{acc | rows: [row | acc.rows]}
  end

  defp note(acc, e, lane_key, label, tone) do
    acc = lane(acc, lane_key)

    row = %{
      type: :note,
      lane: lane_key,
      label: clip(label),
      tone: tone,
      count: 1,
      at: at(e),
      seq: e["seq"],
      fold: nil
    }

    %{acc | rows: [row | acc.rows]}
  end

  # Output and progress fold into one note per lane until the lane talks.
  defp fold(acc, e, lane_key, kind, text, tone) do
    acc = lane(acc, lane_key)

    case acc.open[{lane_key, kind}] do
      nil ->
        row = %{
          type: :note,
          lane: lane_key,
          label: clip(text),
          tone: tone,
          count: 1,
          at: at(e),
          seq: e["seq"],
          fold: kind
        }

        idx = length(acc.rows)
        %{acc | rows: [row | acc.rows], open: Map.put(acc.open, {lane_key, kind}, idx)}

      idx ->
        # Rows are kept newest first; idx counts from the oldest.
        pos = length(acc.rows) - 1 - idx
        rows = List.update_at(acc.rows, pos, &%{&1 | label: clip(text), count: &1.count + 1})
        %{acc | rows: rows}
    end
  end

  defp close(acc, lane_key),
    do: %{acc | open: Map.reject(acc.open, fn {{l, _}, _} -> l == lane_key end)}

  defp divider(acc, e, label),
    do: %{acc | rows: [%{type: :divider, label: label, at: at(e), seq: e["seq"]} | acc.rows]}

  ## Lanes

  defp lane(acc, key) do
    if Map.has_key?(acc.lanes, key),
      do: acc,
      else: %{acc | lanes: Map.put(acc.lanes, key, true), order: [key | acc.order]}
  end

  # Model and Universe first, the handle store last, workers in between.
  defp lanes(acc) do
    order = Enum.reverse(acc.order)

    workers =
      Enum.filter(order, &(String.starts_with?(&1, "w:") or String.starts_with?(&1, "svc:")))

    (["model", "universe"] ++ workers ++ Enum.filter(["handles"], &(&1 in order)))
    |> Enum.map(&lane_info(&1, acc.info))
  end

  defp lane_info("model", _),
    do: %{key: "model", label: "Model", sub: "Claude Code", kind: :model}

  defp lane_info("universe", _),
    do: %{key: "universe", label: "Universe", sub: "Tick · kernel", kind: :universe}

  defp lane_info("handles", _),
    do: %{key: "handles", label: "Handles", sub: "data store", kind: :handles}

  defp lane_info("svc:" <> name = key, _),
    do: %{key: key, label: name, sub: "service", kind: :service}

  defp lane_info("w:" <> sid = key, info) do
    id = String.to_integer(sid)
    i = info[id] || %{label: "?", kind: "run", lang: nil}

    {sub, kind} =
      cond do
        i.lang == "agent" -> {"agent", :agent}
        i.kind == "serve" -> {"service · #{i.lang}", :service}
        true -> {"#{i.kind} · #{i.lang}", :run}
      end

    %{key: key, label: "##{id} #{i.label}", sub: sub, kind: kind}
  end

  defp remember(acc, %{"id" => id}, worker) when is_integer(id) do
    if Map.has_key?(acc.info, id), do: acc, else: put_in(acc.info[id], worker.(id))
  end

  defp remember(acc, _e, _worker), do: acc

  defp service_lane(name, seq, owner) do
    case owner.(name, seq) do
      id when is_integer(id) -> w(id)
      _ -> "svc:" <> to_string(name)
    end
  end

  defp w(id), do: "w:#{id}"

  ## Lookups (defaults read the event log)

  @doc false
  def worker_info(id) do
    events = EventLog.for_id(id)
    first = Enum.find(events, &(&1["type"] in ["queued", "spawn"]))
    spawn = Enum.find(events, &(&1["type"] == "spawn"))

    %{
      label: (first && first["data"]["label"]) || "?",
      kind: (first && first["data"]["kind"]) || "run",
      lang: spawn && spawn["data"]["lang"]
    }
  end

  # The worker that served `name` at `seq`: the latest serve before it.
  defp owner_lookup do
    serves = EventLog.by_types(["serve"])

    fn name, seq ->
      serves
      |> Enum.filter(&(&1["data"]["name"] == name and &1["seq"] < seq))
      |> List.last()
      |> case do
        nil -> nil
        e -> e["id"]
      end
    end
  end

  ## Text

  defp directives_text(d) do
    ds = List.wrap(d["directives"])

    # Counts per op, in the order the model sent them.
    ops = Enum.map(ds, &(is_map(&1) && &1["op"]))
    counts = Enum.frequencies(ops)

    case Enum.uniq(ops) do
      [] -> "wait"
      order -> Enum.map_join(order, ", ", &"#{counts[&1]} #{&1}")
    end
  end

  defp output_line(%{"truncated" => true}), do: "output truncated (rest on disk)"

  defp output_line(%{"text" => t}) when is_binary(t),
    do: t |> String.split("\n", trim: true) |> List.last() || ""

  defp output_line(_), do: ""

  defp exit_tone("done"), do: :good
  defp exit_tone(s) when s in ["failed", "budget"], do: :bad
  defp exit_tone(_), do: :muted

  defp dur(ms) when is_integer(ms), do: Digest.duration(ms)
  defp dur(_), do: nil

  defp clip(nil), do: ""

  defp clip(text) do
    text = text |> to_string() |> String.replace(~r/\s+/, " ")
    if String.length(text) > 300, do: String.slice(text, 0, 300) <> "…", else: text
  end

  defp at(%{"ts" => ts}) when is_binary(ts) do
    case Regex.run(~r/T(\d\d:\d\d:\d\d)/, ts) do
      [_, t] -> t
      _ -> ""
    end
  end

  defp at(_), do: ""
end
