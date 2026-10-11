defmodule UniverseWeb.Activity do
  @moduledoc """
  Turns raw event-log entries into what the observer shows: one readable
  line per event for the activity feed, and an agent's task history.
  Pure functions over events; no state.
  """

  alias Universe.{Digest, EventLog}

  @groups %{
    "model" => ~w(tick_in tick_out rejected reply redirect),
    "lifecycle" => ~w(queued spawn serve exit restart budget_hit gc stop_all lease),
    "agents" => ~w(call ask progress put),
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
      type: type,
      id: e["id"],
      tick: e["tick"],
      tone: tone,
      text: clip(text, 220)
    }
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

    case d["prompt"] do
      prompt when is_binary(prompt) -> {:info, "task → #{target}: #{prompt}"}
      _ -> {:info, "call → #{target}.#{d["fn"]} #{d["args"]}"}
    end
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

    detail =
      d["reason"] || (d["handle"] && "→ #{d["handle"]}") ||
        (d["result_text"] && "→ #{result_text(d["result_text"])}") || d["last_err"] ||
        d["last_out"]

    took = d["wall_ms"] && Digest.duration(d["wall_ms"])
    {tone, Enum.join(Enum.filter([d["status"], took, detail], & &1), " · ")}
  end

  defp line("restart", d), do: {:warn, "restarting (attempt #{d["attempt"]}) · #{d["last_err"]}"}
  defp line("budget_hit", d), do: {:bad, "#{d["budget"]} budget hit (#{d["limit"]})"}

  defp line("gc", %{"action" => "stop_idle"} = d),
    do: {:muted, "stopped idle service #{d["service"]} after #{d["idle_s"]}s"}

  defp line("gc", d), do: {:muted, "gc: #{d["action"]}"}
  defp line("stop_all", d), do: {:warn, "stop all: #{Enum.join(List.wrap(d["ids"]), ", ")}"}

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

  defp time_of(ts) when is_binary(ts) do
    case Regex.run(~r/T(\d\d:\d\d:\d\d)/, ts) do
      [_, t] -> t
      _ -> ts
    end
  end

  defp time_of(_), do: ""
end
