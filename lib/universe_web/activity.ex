defmodule UniverseWeb.Activity do
  @moduledoc """
  Turns raw event-log entries into what the observer shows: one readable
  line per event for the activity feed, and an agent's task history.
  Pure functions over events; no state.
  """

  alias Universe.{Digest, EventLog}

  @groups %{
    "model" => ~w(tick_in tick_out rejected reply steer redirect),
    "lifecycle" => ~w(queued spawn serve exit restart budget_hit gc stop_all lease),
    "agents" => ~w(call call_done ask progress put get steer_dropped),
    "output" => ~w(stdout stderr)
  }

  @doc "Feed filters, in display order."
  def filters, do: ["all", "model", "agents", "lifecycle", "output"]

  @doc "Whether an event belongs to a feed filter."
  def in_filter?(_event, "all"), do: true
  def in_filter?(%{"type" => type}, filter), do: type in Map.get(@groups, filter, [])

  @doc """
  One feed line: `%{seq, at, type, id, tone, text}`. `tone` is one of
  `:model`, `:good`, `:bad`, `:warn`, `:info`, `:muted`.
  """
  def describe(%{"type" => type} = e) do
    data = e["data"] || %{}
    {tone, text} = line(type, data)

    %{
      # Progress is one row per worker, replaced as it changes.
      key: if(type == "progress" and e["id"], do: "p-#{e["id"]}", else: "ev-#{e["seq"]}"),
      seq: e["seq"],
      at: time_of(e["ts"]),
      ts: e["ts"],
      type: type,
      count: 1,
      fold: nil,
      id: e["id"],
      tick: e["tick"],
      tone: tone,
      text: clip(text, 220)
    }
  end

  ## Folding

  # How many of the newest rows a repeat may fold into.
  @fold_window 6

  @doc """
  An empty feed state for `feed_step/2`.
  """
  def new_feed, do: %{folds: %{}, recent: []}

  @doc """
  Adds one event to the feed: `{state, {:insert, row}}`, or `{state,
  {:update, row}}` when the event folds into a recent row. Repeats fold:
  a worker's `U.call`s to the same function (with their answers), its reads
  and its stores become one row with a count instead of one row each.
  Calls with a prompt (agent tasks) never fold.
  """
  def feed_step(state, e) do
    row = describe(e)

    case fold_key(e) do
      nil ->
        {push(state, row), {:insert, row}}

      fk ->
        case state.folds[fk] do
          %{key: key} = head ->
            if key in state.recent do
              merged = merge(head, e)
              {state |> push(merged) |> put_in([:folds, fk], merged), {:update, merged}}
            else
              start(state, fk, row, e)
            end

          nil ->
            start(state, fk, row, e)
        end
    end
  end

  @doc "Folds a list of events (oldest first) into feed rows, newest first."
  def fold(events, state \\ new_feed()) do
    {state, rows} =
      Enum.reduce(events, {state, []}, fn e, {st, rows} ->
        {st, {_, row}} = feed_step(st, e)
        {st, [row | Enum.reject(rows, &(&1.key == row.key))]}
      end)

    {state, rows}
  end

  defp start(state, fk, row, e) do
    row = merge(Map.merge(row, %{fold: fk, stats: %{n: 0, done: 0, wall: nil, last: nil}}), e)
    {state |> push(row) |> put_in([:folds, fk], row), {:insert, row}}
  end

  defp push(state, row),
    do: %{state | recent: Enum.take([row.key | List.delete(state.recent, row.key)], @fold_window)}

  defp fold_key(%{"type" => "call", "id" => id, "data" => %{"via" => "sdk"} = d}) do
    cond do
      is_binary(d["prompt"]) or d["ok"] == false -> nil
      true -> {:call, id, d["service"], d["fn"]}
    end
  end

  defp fold_key(%{"type" => "call_done", "id" => id, "data" => %{"ok" => true} = d}),
    do: {:call, id, d["service"], d["fn"]}

  defp fold_key(%{"type" => t, "id" => id}) when t in ["get", "put"] and is_integer(id),
    do: {t, id}

  defp fold_key(_e), do: nil

  defp merge(%{fold: {:call, _, svc, fun}} = row, e) do
    st = row.stats

    st =
      case e do
        # Newer logs: one event per answered call.
        %{"type" => "call", "data" => %{"ok" => _} = d} ->
          %{st | n: st.n + 1, done: st.done + 1, wall: d["wall_ms"]}

        %{"type" => "call"} ->
          %{st | n: st.n + 1}

        _ ->
          %{st | done: st.done + 1, wall: e["data"]["wall_ms"]}
      end

    flight = if st.n > st.done, do: " · #{st.n - st.done} in flight", else: ""
    took = if st.wall, do: " · last took #{Digest.duration(st.wall)}", else: ""

    text =
      if st.n <= 1 and st.done <= 1,
        do: if(e["type"] == "call", do: row.text, else: "U.call → #{svc}.#{fun} answered#{took}"),
        else: "U.call → #{svc}.#{fun} · #{st.n} calls#{flight}#{took}"

    %{
      row
      | stats: st,
        count: max(st.n, 1),
        text: clip(text, 220),
        at: time_of(e["ts"]),
        ts: e["ts"]
    }
  end

  defp merge(%{fold: {kind, _}} = row, e) when kind in ["get", "put"] do
    st = %{row.stats | n: row.stats.n + 1, last: e["data"]["handle"]}
    verb = if kind == "get", do: "read", else: "stored"

    text =
      if st.n == 1,
        do: elem(line(kind, e["data"] || %{}), 1),
        else: "#{verb} #{st.n} handles · last #{st.last}"

    %{row | stats: st, count: st.n, text: clip(text, 220), at: time_of(e["ts"]), ts: e["ts"]}
  end

  defp line("tick_in", d) do
    n = length(List.wrap(d["directives"]))

    ops =
      d["directives"] |> List.wrap() |> Enum.map(&(is_map(&1) && &1["op"])) |> Enum.frequencies()

    detail = ops |> Enum.map_join(", ", fn {op, c} -> "#{c} #{op}" end)
    {:model, "model sent #{n} directive(s)#{if detail != "", do: ": " <> detail}"}
  end

  defp line("tick_out", d),
    do:
      {:model,
       "digest back to the model · #{d["wake"]} · ~#{d["tokens_out_est"]} tokens · waited #{Digest.duration(d["wait_ms"])}"}

  defp line("rejected", d), do: {:bad, "rejected #{d["label"] || d["op"]}: #{d["reason"]}"}
  defp line("reply", d), do: {:model, "model replied: #{d["text"]}"}

  defp line("steer", d),
    do: {:model, "model steered#{if d["interrupt"], do: " (interrupting)"}: #{d["text"]}"}

  defp line("steer_dropped", d), do: {:warn, "steer not delivered, #{d["reason"]}: #{d["text"]}"}
  defp line("redirect", d), do: {:warn, "Bash call redirected to Universe: #{d["command"]}"}
  defp line("queued", d), do: {:muted, "queued #{d["label"]}#{after_text(d)}"}

  defp line("spawn", d) do
    what = if d["lang"] == "agent", do: "agent", else: "#{d["kind"]} · #{d["lang"]}"
    {:info, "started #{d["label"]} (#{what})"}
  end

  defp line("serve", d),
    do: {:good, "serving #{d["name"]} · #{d["describe"] || Enum.join(List.wrap(d["fns"]), ", ")}"}

  defp line("call", d) do
    target = if d["pool"], do: "#{d["service"]} (pool #{d["pool"]})", else: d["service"]

    by = if d["via"] == "sdk", do: "U.call ", else: ""

    case d do
      %{"prompt" => prompt} when is_binary(prompt) ->
        {:info, "#{by}task → #{target}: #{prompt}"}

      # A U.call logged once, when it was answered.
      %{"ok" => ok} ->
        took = d["wall_ms"] && " in #{Digest.duration(d["wall_ms"])}"
        verb = if ok, do: "answered", else: "failed"
        {if(ok, do: :info, else: :bad), "#{by}call → #{target}.#{d["fn"]} #{verb}#{took}"}

      _ ->
        {:info, String.trim("#{by}call → #{target}.#{d["fn"]} #{d["args"]}")}
    end
  end

  defp line("call_done", d) do
    took = d["wall_ms"] && " · #{Digest.duration(d["wall_ms"])}"

    {if(d["ok"], do: :muted, else: :bad),
     "← #{d["service"]}.#{d["fn"]} #{if d["ok"], do: "answered", else: "failed"}#{took}"}
  end

  defp line("get", d) do
    verb = if d["preview"], do: "previewed", else: "read"
    {:muted, "#{verb} #{d["handle"]}#{if d["ok"] == false, do: " (missing)"}"}
  end

  defp line("ask", d), do: {:warn, "asks the model: #{d["question"]}"}
  defp line("progress", d), do: {:muted, d["text"]}
  defp line("put", d), do: {:info, "stored #{d["handle"]} (#{d["summary"]})"}

  defp line("stdout", %{"truncated" => true}),
    do: {:muted, "stdout truncated (rest kept on disk)"}

  defp line("stdout", d), do: {:muted, first_line(d["text"])}

  defp line("stderr", %{"truncated" => true}),
    do: {:muted, "stderr truncated (rest kept on disk)"}

  defp line("stderr", d), do: {:bad, first_line(d["text"])}

  defp line("exit", d) do
    tone =
      case d["status"] do
        "done" -> :good
        s when s in ["failed", "budget"] -> :bad
        _ -> :muted
      end

    # A killed worker's last output line is not why it ended.
    last = if d["status"] == "killed", do: nil, else: d["last_err"] || d["last_out"]

    detail =
      d["reason"] || (d["handle"] && "→ #{d["handle"]}") ||
        (d["result_text"] && "→ #{result_text(d["result_text"])}") || last

    took = d["wall_ms"] && Digest.duration(d["wall_ms"])
    {tone, Enum.join(Enum.filter([d["status"], took, detail], & &1), " · ")}
  end

  defp line("restart", d), do: {:warn, "restarting (attempt #{d["attempt"]}) · #{d["last_err"]}"}
  defp line("budget_hit", d), do: {:bad, "#{d["budget"]} budget hit (#{d["limit"]})"}

  defp line("gc", %{"action" => "stop_idle"} = d),
    do: {:muted, "stopped idle service #{d["service"]} after #{d["idle_s"]}s"}

  defp line("gc", %{"action" => "prune_log"} = d),
    do: {:muted, "deleted rotated event log #{d["file"]}"}

  defp line("gc", d), do: {:muted, "gc: #{d["action"]}"}

  defp line("log_rotated", d),
    do: {:muted, "event log rotated: full log in #{d["archive"]}, #{d["kept"]} events kept"}

  defp line("stop_all", d), do: {:warn, "stop all: #{Enum.join(List.wrap(d["ids"]), ", ")}"}

  defp line("lease", %{"action" => "wait", "note" => note}), do: {:warn, note}

  defp line("lease", d),
    do: {:muted, "lease #{d["action"]}: #{Enum.join(List.wrap(d["paths"]), ", ")}"}

  defp line(type, _d), do: {:muted, type}

  defp after_text(%{"after" => [_ | _] = deps}), do: " after #{Enum.join(deps, ", ")}"
  defp after_text(_), do: ""

  @doc """
  An agent's tasks, newest first: `%{id, prompt, status, answer, handle,
  reason, wall_ms, at}`, from the `call` events aimed at `service` and their
  `exit` events. Running tasks have status `"running"`.
  """
  def agent_tasks(service) do
    calls =
      EventLog.by_types(["call"])
      |> Enum.filter(&(&1["data"]["service"] == service and is_binary(&1["data"]["prompt"])))

    Enum.map(calls, fn c ->
      exit = EventLog.for_id(c["id"]) |> Enum.find(&(&1["type"] == "exit"))
      d = (exit && exit["data"]) || %{}

      %{
        id: c["id"],
        at: time_of(c["ts"]),
        prompt: c["data"]["prompt"],
        status: d["status"] || "running",
        answer: result_text(d["result_text"]),
        handle: d["handle"],
        reason: d["reason"],
        wall_ms: d["wall_ms"]
      }
    end)
    |> Enum.reverse()
  end

  @doc """
  A call result for people: results are stored JSON-encoded, so a string
  answer arrives as `"\"text\\nmore\""`. Strings are decoded; anything else
  stays JSON.
  """
  def result_text(nil), do: nil

  def result_text(text) do
    case Jason.decode(text) do
      {:ok, s} when is_binary(s) -> s
      _ -> text
    end
  end

  defp first_line(nil), do: ""

  defp first_line(text) do
    lines = text |> String.split("\n", trim: true)

    case lines do
      [] -> ""
      [one] -> one
      [first | rest] -> "#{first} (+#{length(rest)} lines)"
    end
  end

  defp clip(nil, _), do: ""

  defp clip(text, max) do
    text = to_string(text)
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp time_of(ts), do: UniverseWeb.Format.clock(ts)
end
