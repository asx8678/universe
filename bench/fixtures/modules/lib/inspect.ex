defmodule Universe.Inspect do
  @moduledoc """
  The `inspect` tool: a closer look at something a digest pointed at.

    * `manifest` - live workers, held leases, saved tools (services in M2)
    * `#5`       - worker card, its code, and its output (tail by default)
    * `t12`      - every event of tick 12, one line each
    * `h:5/name` - handle preview (schema and first rows, keys, or head)

  Built from the event log and the run directory, so it also answers for
  workers from before a daemon restart. Pages with `offset`/`limit` (lines)
  and filters with `grep` (a regex, or a plain substring if it doesn't
  compile). Output stays under ~8,000 tokens.
  """

  alias Universe.{Digest, EventLog, Handles, Paths, Tick, Worker}

  @max_chars 32_000
  @default_limit 200
  @max_limit 2_000
  @code_lines 80

  def run(args) do
    opts = %{
      offset: int(args["offset"], nil),
      limit: args["limit"] |> int(@default_limit) |> max(1) |> min(@max_limit),
      grep: matcher(args["grep"])
    }

    target = args["target"] |> to_string() |> String.trim()

    text =
      case target do
        "manifest" -> manifest()
        "#" <> n -> with_int(n, target, &worker(&1, opts))
        "t" <> n -> with_int(n, target, &tick(&1, opts))
        "h:" <> _ -> handle(target)
        "" -> "inspect needs a target: manifest, #<id>, t<n> or h:<id>/<name>"
        other -> "unknown target #{inspect(other)}: use manifest, #<id>, t<n> or h:<id>/<name>"
      end

    %{text: cap(text), structured: %{"target" => target}}
  end

  ## manifest

  # Agents show whether they can take a task now: idle, busy or asking.
  defp agent_status(%{spec: %{agent: %{} = agent}, status: status}, busy, name) do
    state =
      cond do
        status != "serving" -> status
        MapSet.member?(busy, name) -> "busy"
        true -> "idle"
      end

    Enum.join(["agent", agent.pool && "pool #{agent.pool}", state] |> Enum.filter(& &1), ", ")
  end

  defp agent_status(w, _busy, _name), do: w.status

  @doc "The manifest as plain text (also served to the SessionStart hook)."
  def manifest do
    workers = Tick.snapshot()

    live =
      workers
      |> Map.values()
      |> Enum.filter(&(&1.status in ["queued", "running", "serving", "asking"]))

    services = live |> Enum.filter(&(&1.kind == "serve")) |> Enum.sort_by(& &1.id)
    others = live |> Enum.reject(&(&1.kind == "serve")) |> Enum.sort_by(& &1.id)
    leases = Tick.leases()
    tools = list_tools()
    handles = Handles.list()

    busy =
      for w <- others,
          w.kind == "call",
          w.status == "running",
          into: MapSet.new(),
          do: w.spec.service

    service_lines =
      Enum.map(services, fn w ->
        fns = if w.fns == [], do: "", else: " · fns: #{Enum.join(w.fns, ", ")}"
        desc = if w.describe in [nil, ""], do: "", else: " · #{w.describe}"
        name = w.service || w.spec.service
        "  #{name} (##{w.id}, #{agent_status(w, busy, name)})#{fns}#{desc}"
      end)

    lines =
      [
        "manifest · #{Paths.project_root()}",
        "services: #{if services == [], do: "none", else: length(services)}"
      ] ++
        service_lines ++
        ["live workers: #{length(others)}"] ++
        Enum.map(others, &"  ##{&1.id} #{&1.status} #{&1.label}") ++
        ["leases: #{if leases == %{}, do: "none", else: ""}"] ++
        Enum.map(Enum.sort(leases), fn {id, paths} -> "  ##{id} #{Enum.join(paths, ", ")}" end) ++
        ["handles: #{length(handles)}#{recent_handles(handles)}"] ++
        ["saved tools: #{if tools == [], do: "none", else: Enum.join(tools, ", ")}"]

    Enum.join(lines, "\n")
  end

  defp recent_handles([]), do: ""

  defp recent_handles(handles) do
    shown = handles |> Enum.take(-5) |> Enum.map_join(", ", & &1["handle"])
    " (latest: #{shown})"
  end

  ## h:<id>/<name>

  defp handle(target) do
    case Handles.preview(target) do
      {:ok, text} -> text
      {:error, reason} -> reason
    end
  end

  defp list_tools do
    case File.ls(Paths.tools_dir()) do
      {:ok, files} -> Enum.sort(files)
      {:error, _} -> []
    end
  end

  ## #id

  defp worker(id, opts) do
    events = EventLog.for_id(id)

    case Enum.find(events, &(&1["type"] in ["spawn", "queued"])) do
      nil ->
        "##{id}: no such worker"

      _ ->
        spawn = Enum.find(events, &(&1["type"] == "spawn"))
        exit = Enum.find(events, &(&1["type"] == "exit"))
        live = Map.get(Tick.snapshot(), id)
        dir = Worker.run_dir(id)

        ([card(id, events, spawn, exit, live), code(dir, spawn), call_section(events, exit)] ++
           outputs(dir, opts))
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
    end
  end

  defp card(id, events, spawn, exit, live) do
    first = hd(events)
    label = (spawn && spawn["data"]["label"]) || get_in(first, ["data", "label"]) || "?"
    status = (live && live.status) || (exit && exit["data"]["status"]) || "unknown"
    x = (exit && exit["data"]) || %{}

    head =
      Enum.reject(
        [
          "##{id} #{label}",
          spawn && spawn["data"]["lang"],
          status,
          x["code"] && "exit #{x["code"]}",
          x["signal"] && "signal #{x["signal"]}",
          x["wall_ms"] && Digest.duration(x["wall_ms"]),
          x["reason"],
          "tick t#{first["tick"]}"
        ],
        &is_nil/1
      )

    budget =
      if spawn do
        b = spawn["data"]["budget"]
        leases = spawn["data"]["leases"]

        "budget wall #{b["wall_s"]}s, out #{b["out_kb"]} KB · leases: #{if leases == [], do: "none", else: Enum.join(leases, ", ")}"
      end

    Enum.reject([Enum.join(head, " · "), budget, "run dir: .universe/runs/#{id}"], &is_nil/1)
    |> Enum.join("\n")
  end

  defp call_section(events, exit) do
    case Enum.find(events, &(&1["type"] == "call")) do
      nil ->
        nil

      call ->
        d = call["data"]
        x = (exit && exit["data"]) || %{}

        result =
          cond do
            is_binary(x["handle"]) -> "result: #{x["handle"]} (#{x["handle_summary"]})"
            Map.has_key?(x, "result_text") -> "result: #{x["result_text"]}"
            true -> nil
          end

        ["--- call #{d["service"]}.#{d["fn"]}", "args: #{d["args"]}", result]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
    end
  end

  defp code(_dir, nil), do: nil

  defp code(dir, spawn) do
    file = Worker.code_file(spawn["data"]["lang"])

    case File.read(Path.join(dir, file)) do
      {:ok, text} ->
        lines = String.split(text, "\n")
        shown = Enum.take(lines, @code_lines)
        more = length(lines) - length(shown)

        Enum.join(
          ["--- code (#{file}, #{length(lines)} lines)"] ++
            shown ++ if(more > 0, do: ["… #{more} more lines"], else: []),
          "\n"
        )

      {:error, _} ->
        "--- code: #{file} not found"
    end
  end

  defp outputs(dir, opts) do
    for stream <- ["stdout", "stderr"] do
      case File.read(Path.join(dir, stream)) do
        {:ok, ""} ->
          "--- #{stream}: empty"

        {:ok, text} ->
          page(
            "--- #{stream}",
            text |> Worker.utf8() |> String.split("\n") |> drop_last_empty(),
            opts
          )

        {:error, _} ->
          nil
      end
    end
  end

  ## t<n>

  defp tick(n, opts) do
    case EventLog.for_tick(n) do
      [] -> "t#{n}: no events"
      events -> page("t#{n} · #{length(events)} events", Enum.map(events, &event_line/1), opts)
    end
  end

  defp event_line(e) do
    id = if e["id"], do: " ##{e["id"]}", else: ""
    "#{e["seq"]} #{e["type"]}#{id} #{summary(e["type"], e["data"])}" |> String.trim_trailing()
  end

  defp summary("tick_in", d),
    do: "#{length(List.wrap(d["directives"]))} directive(s) · wait #{Jason.encode!(d["wait"])}"

  defp summary("tick_out", d),
    do:
      "wake #{d["wake"]} · waited #{Digest.duration(d["wait_ms"])} · ~#{d["tokens_out_est"]} tokens out"

  defp summary("rejected", d), do: "#{d["label"] || d["op"] || "?"}: #{d["reason"]}"

  defp summary("queued", d),
    do:
      join([
        d["label"],
        d["after"] not in [nil, []] && "after #{Enum.join(d["after"], ", ")}",
        d["then_of"] && "then of #{d["then_of"]}"
      ])

  defp summary("spawn", d), do: "#{d["label"]} · #{d["lang"]}"
  defp summary("exit", d), do: join([d["status"], d["code"] && "exit #{d["code"]}", d["reason"]])
  defp summary("lease", d), do: "#{d["action"]} #{Enum.join(d["paths"], ", ")}"
  defp summary("budget_hit", d), do: "#{d["budget"]} #{d["limit"]}"

  defp summary(type, %{"truncated" => true}) when type in ["stdout", "stderr"],
    do: "(truncated; rest on disk)"

  defp summary(type, %{"text" => text}) when type in ["stdout", "stderr"],
    do: text |> String.split("\n") |> hd() |> String.slice(0, 120)

  defp summary(_type, d), do: d |> Jason.encode!() |> String.slice(0, 160)

  defp join(parts), do: parts |> Enum.filter(&is_binary/1) |> Enum.join(" · ")

  ## Paging

  # Tail by default; `offset` (0-based line) switches to a forward page.
  defp page(title, lines, opts) do
    lines = if opts.grep, do: Enum.filter(lines, opts.grep), else: lines
    total = length(lines)

    {from, shown} =
      case opts.offset do
        nil ->
          from = max(total - opts.limit, 0)
          {from, Enum.slice(lines, from, opts.limit)}

        offset ->
          {offset, Enum.slice(lines, offset, opts.limit)}
      end

    range = if shown == [], do: "none", else: "lines #{from + 1}-#{from + length(shown)}"
    grep = if opts.grep, do: " matching", else: ""
    Enum.join(["#{title} (#{range} of #{total}#{grep})" | shown], "\n")
  end

  defp drop_last_empty(lines),
    do: if(List.last(lines) == "", do: Enum.drop(lines, -1), else: lines)

  defp matcher(nil), do: nil
  defp matcher(""), do: nil

  defp matcher(pattern) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, re} -> &Regex.match?(re, &1)
      {:error, _} -> &String.contains?(&1, pattern)
    end
  end

  defp matcher(_), do: nil

  defp cap(text) do
    if String.length(text) > @max_chars do
      String.slice(text, 0, @max_chars - 80) <>
        "\n… cut at ~8,000 tokens; page with offset/limit or narrow with grep"
    else
      text
    end
  end

  defp with_int(n, target, fun) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> fun.(i)
      _ -> "unknown target #{inspect(target)}"
    end
  end

  defp int(v, _default) when is_integer(v) and v >= 0, do: v
  defp int(_, default), do: default
end
