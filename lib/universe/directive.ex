defmodule Universe.Directive do
  @moduledoc """
  Validates a tick's batch of directives. Never raises: every problem becomes
  a rejection `%{label, op, reason}` that the digest shows as a `rejected` line.

  Accepted directives come back normalised (atom keys, defaults applied):

      %{op: "run", label: "pg-extract", lang: "python", code: "...",
        budget: %{wall_s: 120, out_kb: 256}, leases: [], after: ["#3", "dedupe"],
        then: [%{op: "run", ...}], quiet: false}

      %{op: "serve", label: "pg", service: "pg", lang:, code:, budget:, leases:,
        network: ["db.internal:5432"], ttl_idle_s: 900, after: [], then: [], quiet: false}

      %{op: "serve", label: "reviewer", service: "reviewer", lang: "agent",
        agent: %{purpose: "...", model: "haiku", tools: ["Read", "Grep"], pool: "reviewers"},
        code: "<agent config JSON>", ...}

      %{op: "call", label: "count", service: "pg", fn: "query", args: %{...},
        timeout_s: 60, after: [], then: [], quiet: false}

  A call with `prompt` instead of `fn`/`args` is a task for an agent:
  `fn: "task", args: %{"prompt" => prompt}`. A call's `service` may also name
  an agent pool.

      %{op: "kill", label: nil | "stop-pg", target: "#5" | "pg"}
      %{op: "reply", label: nil, target: "#9" | "ui-build", text: "use the new file"}

  Rules:
    * labels are 1-40 chars of letters, digits, `_ . -` and unique across the
      batch, `then` steps included
    * `after` names labels of this batch's top-level directives, or labels/IDs
      the resolver knows from earlier ticks; `then` steps can't be targets and
      can't have `after` themselves
    * cycles in `after` are rejected, and so is anything depending on a
      rejected directive
    * unknown ops and unknown fields are rejected, not ignored
  """

  @label_re ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$/
  @id_re ~r/^#(\d+)$/

  @run_fields ~w(op label lang code budget leases after then quiet)
  @serve_fields ~w(op label name lang code agent budget leases network ttl_idle_s after quiet)
  @call_fields ~w(op label service fn args prompt timeout_s after quiet)
  @agent_fields ~w(purpose model tools pool resume)
  # Built-in tools an agent may get. Code-running tools never: an agent runs
  # code through Universe workers, which are sandboxed.
  @agent_tools ~w(Read Grep Glob Edit Write NotebookEdit WebSearch WebFetch TodoWrite)
  @agent_write_tools ~w(Edit Write NotebookEdit)
  @default_agent_tools ~w(Read Grep Glob)
  @max_purpose_bytes 16 * 1024
  @kill_fields ~w(op label target)
  @reply_fields ~w(op label target text)
  @budget_fields ~w(wall_s out_kb mem_mb)

  @run_defaults %{wall_s: 120, out_kb: 256, mem_mb: 2048}
  # Services have no wall clock unless asked for one.
  @serve_defaults %{wall_s: nil, out_kb: 256, mem_mb: 2048}
  @limits %{wall_s: 86_400, out_kb: 4096, mem_mb: 16_384}
  @default_ttl_s 900
  # Agent tasks can take a while.
  @max_call_timeout_s 1800
  @max_code_bytes 256 * 1024
  @max_directives 64

  @type rejection :: %{label: String.t() | nil, op: String.t() | nil, reason: String.t()}

  @doc """
  Validates `directives`. `resolve` answers references from earlier ticks:
  `fn "#5" | "label" -> {:ok, id} | :error end`.
  """
  @spec validate(term(), (String.t() -> {:ok, pos_integer()} | :error)) ::
          {[map()], [rejection()]}
  def validate(directives, resolve \\ fn _ -> :error end)

  def validate(nil, _resolve), do: {[], []}

  def validate(directives, _resolve) when not is_list(directives),
    do: {[], [reject(nil, nil, "directives must be a list")]}

  def validate(directives, _resolve) when length(directives) > @max_directives,
    do: {[], [reject(nil, nil, "at most #{@max_directives} directives per tick")]}

  def validate(directives, resolve) do
    {ok, rejected} =
      directives
      |> Enum.map(&normalize(&1, false))
      |> Enum.split_with(&match?({:ok, _}, &1))

    ok = Enum.map(ok, fn {:ok, d} -> d end)
    rejected = Enum.map(rejected, fn {:error, r} -> r end)

    {ok, dup_rejected} = reject_duplicates(ok)
    # Refs to directives already rejected are left for propagate/2 to explain.
    gone =
      (rejected ++ dup_rejected) |> Enum.map(& &1.label) |> Enum.reject(&is_nil/1) |> MapSet.new()

    {ok, ref_rejected} = check_after_refs(ok, resolve, gone)
    {ok, cycle_rejected} = reject_cycles(ok)
    {ok, dep_rejected} = propagate(ok, rejected ++ dup_rejected ++ ref_rejected ++ cycle_rejected)

    {ok, rejected ++ dup_rejected ++ ref_rejected ++ cycle_rejected ++ dep_rejected}
  end

  @doc "Parses `#5` into 5."
  def parse_id(ref) when is_binary(ref) do
    case Regex.run(@id_re, ref) do
      [_, n] -> {:ok, String.to_integer(n)}
      nil -> :error
    end
  end

  def parse_id(_), do: :error

  ## Shape

  defp normalize(d, nested?) when is_map(d) do
    op = d["op"]
    label = if is_binary(d["label"]), do: d["label"]

    result =
      case op do
        "run" -> run(d, nested?)
        op when nested? and op != "run" -> {:error, "then steps must be run directives"}
        "serve" -> serve(d)
        "call" -> call(d)
        "kill" -> kill(d)
        "reply" -> reply(d)
        nil -> {:error, "missing op"}
        other -> {:error, "unknown op #{inspect(other)}"}
      end

    case result do
      {:ok, directive} -> {:ok, directive}
      {:error, reason} -> {:error, reject(label, if(is_binary(op), do: op), reason)}
    end
  end

  defp normalize(_d, _nested?), do: {:error, reject(nil, nil, "directive must be an object")}

  defp run(d, nested?) do
    with :ok <- known_fields(d, @run_fields),
         {:ok, label} <- label(d["label"], true),
         {:ok, lang} <- lang(d["lang"]),
         {:ok, code} <- code(d["code"]),
         {:ok, budget} <- budget(d["budget"], @run_defaults),
         {:ok, leases} <- leases(d["leases"]),
         {:ok, after_refs} <- after_refs(d["after"], nested?),
         {:ok, then} <- then_steps(d["then"]),
         {:ok, quiet} <- quiet(d["quiet"]) do
      {:ok,
       %{
         op: "run",
         label: label,
         lang: lang,
         code: code,
         budget: budget,
         leases: leases,
         after: after_refs,
         then: then,
         quiet: quiet
       }}
    end
  end

  defp serve(d) do
    with :ok <- known_fields(d, @serve_fields),
         {:ok, label} <- label(d["label"], true),
         {:ok, name} <- service_name(d["name"] || label),
         {:ok, lang, code, agent} <- serve_body(d),
         {:ok, budget} <- budget(d["budget"], @serve_defaults),
         {:ok, leases} <- leases(d["leases"]),
         {:ok, network} <- network(d["network"]),
         {:ok, ttl} <- int_field(d["ttl_idle_s"], "ttl_idle_s", 1, 86_400, @default_ttl_s),
         {:ok, after_refs} <- after_refs(d["after"], false),
         {:ok, quiet} <- quiet(d["quiet"]) do
      {:ok,
       %{
         op: "serve",
         label: label,
         service: name,
         lang: lang,
         code: code,
         agent: agent,
         budget: budget,
         leases: leases,
         network: network,
         ttl_idle_s: ttl,
         after: after_refs,
         then: [],
         quiet: quiet
       }}
    end
  end

  defp call(d) do
    with :ok <- known_fields(d, @call_fields),
         {:ok, label} <- label(d["label"], true),
         {:ok, service} <- service_name(d["service"]),
         {:ok, fun, args} <- call_target(d),
         {:ok, timeout} <- int_field(d["timeout_s"], "timeout_s", 1, @max_call_timeout_s, 60),
         {:ok, after_refs} <- after_refs(d["after"], false),
         {:ok, quiet} <- quiet(d["quiet"]) do
      {:ok,
       %{
         op: "call",
         label: label,
         service: service,
         fn: fun,
         args: args,
         timeout_s: timeout,
         after: after_refs,
         then: [],
         quiet: quiet
       }}
    end
  end

  # A serve runs either code or an agent (a Claude session with a purpose).
  defp serve_body(%{"agent" => agent} = d) do
    cond do
      Map.has_key?(d, "code") ->
        {:error, "serve takes code or agent, not both"}

      d["lang"] not in [nil, "agent"] ->
        {:error, "an agent serve takes no lang"}

      Map.has_key?(d, "network") ->
        {:error, "agents take no network (they reach only the Claude API)"}

      true ->
        with {:ok, a} <- agent(agent, d["leases"]), do: {:ok, "agent", nil, a}
    end
  end

  defp serve_body(d) do
    with {:ok, lang} <- lang(d["lang"]),
         {:ok, code} <- code(d["code"]),
         do: {:ok, lang, code, nil}
  end

  defp agent(a, leases) when is_map(a) do
    with :ok <- known_fields(a, @agent_fields),
         {:ok, purpose} <- purpose(a["purpose"]),
         {:ok, model} <- model(a["model"]),
         {:ok, tools} <- agent_tools(a["tools"], leases),
         {:ok, pool} <- pool(a["pool"]),
         {:ok, resume} <- resume(a["resume"]) do
      {:ok, %{purpose: purpose, model: model, tools: tools, pool: pool, resume: resume}}
    end
  end

  defp agent(_, _), do: {:error, "agent must be an object: {purpose, model, tools, pool, resume}"}

  defp purpose(p) when is_binary(p) do
    cond do
      String.trim(p) == "" -> {:error, "agent purpose is empty"}
      byte_size(p) > @max_purpose_bytes -> {:error, "agent purpose is over 16 KB"}
      true -> {:ok, p}
    end
  end

  defp purpose(_), do: {:error, "agent needs a purpose (its system prompt)"}

  defp model(nil), do: {:ok, nil}

  defp model(m) when is_binary(m) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._\[\]-]{0,63}$/, m),
      do: {:ok, m},
      else: {:error, "agent model must be a model name or alias like haiku, sonnet, opus"}
  end

  defp model(_), do: {:error, "agent model must be a string"}

  defp agent_tools(nil, _leases), do: {:ok, @default_agent_tools}

  defp agent_tools(tools, leases) when is_list(tools) do
    cond do
      not Enum.all?(tools, &(&1 in @agent_tools)) ->
        bad = Enum.reject(tools, &(&1 in @agent_tools))

        {:error,
         "agent tools #{inspect(bad)} not allowed (allowed: #{Enum.join(@agent_tools, ", ")})"}

      Enum.any?(tools, &(&1 in @agent_write_tools)) and leases in [nil, []] ->
        {:error, "agent tools that write (#{Enum.join(@agent_write_tools, ", ")}) need leases"}

      true ->
        {:ok, Enum.uniq(tools)}
    end
  end

  defp agent_tools(_, _), do: {:error, "agent tools must be a list of tool names"}

  defp resume(nil), do: {:ok, true}
  defp resume(b) when is_boolean(b), do: {:ok, b}
  defp resume(_), do: {:error, "agent resume must be true or false"}

  defp pool(nil), do: {:ok, nil}

  defp pool(p) when is_binary(p) do
    if Regex.match?(@label_re, p),
      do: {:ok, p},
      else: {:error, "agent pool must be 1-40 chars of letters, digits, _ . -"}
  end

  defp pool(_), do: {:error, "agent pool must be a string"}

  defp call_target(%{"prompt" => prompt} = d) do
    cond do
      Map.has_key?(d, "fn") or Map.has_key?(d, "args") ->
        {:error, "a call takes prompt (an agent task) or fn/args, not both"}

      not is_binary(prompt) or String.trim(prompt) == "" ->
        {:error, "prompt must be a non-empty string"}

      true ->
        {:ok, "task", %{"prompt" => prompt}}
    end
  end

  defp call_target(d), do: with({:ok, f} <- fn_name(d["fn"]), do: {:ok, f, d["args"]})

  defp reply(d) do
    with :ok <- known_fields(d, @reply_fields),
         {:ok, label} <- label(d["label"], false),
         {:ok, target} <- target(d["target"]),
         {:ok, text} <- reply_text(d["text"]) do
      {:ok, %{op: "reply", label: label, target: target, text: text}}
    end
  end

  defp service_name(name) when is_binary(name) do
    if Regex.match?(@label_re, name),
      do: {:ok, name},
      else: {:error, "service name must be 1-40 chars of letters, digits, _ . -"}
  end

  defp service_name(nil), do: {:error, "missing service"}
  defp service_name(_), do: {:error, "service must be a string"}

  defp fn_name(f) when is_binary(f) and f != "", do: {:ok, f}
  defp fn_name(_), do: {:error, "call needs fn (a function name), or prompt for an agent"}

  defp reply_text(t) when is_binary(t) and t != "" do
    if byte_size(t) <= 64 * 1024, do: {:ok, t}, else: {:error, "reply text is over 64 KB"}
  end

  defp reply_text(_), do: {:error, "reply needs text"}

  defp network(nil), do: {:ok, []}

  defp network(list) when is_list(list) do
    if Enum.all?(list, &host_port?/1),
      do: {:ok, Enum.uniq(list)},
      else: {:error, "network entries must be \"host:port\" strings"}
  end

  defp network(_), do: {:error, "network must be a list of \"host:port\""}

  defp host_port?(hp) when is_binary(hp) do
    case Regex.run(~r/^(\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]+):(\d{1,5})$/, hp) do
      [_, _host, port] -> String.to_integer(port) in 1..65_535
      nil -> false
    end
  end

  defp host_port?(_), do: false

  defp int_field(nil, _name, _min, _max, default), do: {:ok, default}

  defp int_field(n, _name, min, max, _default) when is_integer(n) and n >= min and n <= max,
    do: {:ok, n}

  defp int_field(_, name, min, max, _default),
    do: {:error, "#{name} must be an integer #{min}-#{max}"}

  defp kill(d) do
    with :ok <- known_fields(d, @kill_fields),
         {:ok, label} <- label(d["label"], false),
         {:ok, target} <- target(d["target"]) do
      {:ok, %{op: "kill", label: label, target: target}}
    end
  end

  defp known_fields(d, allowed) do
    case Map.keys(d) -- allowed do
      [] ->
        :ok

      unknown ->
        {:error, "unknown field#{plural(unknown)} #{Enum.join(Enum.sort(unknown), ", ")}"}
    end
  end

  defp label(nil, true), do: {:error, "missing label"}
  defp label(nil, false), do: {:ok, nil}

  defp label(label, _required) when is_binary(label) do
    if Regex.match?(@label_re, label),
      do: {:ok, label},
      else: {:error, "label must be 1-40 chars of letters, digits, _ . -"}
  end

  defp label(_, _), do: {:error, "label must be a string"}

  defp lang(lang) do
    langs = Universe.Worker.langs()

    cond do
      is_nil(lang) -> {:error, "missing lang (#{Enum.join(Enum.sort(langs), ", ")})"}
      lang in langs -> {:ok, lang}
      true -> {:error, "unknown lang #{inspect(lang)} (#{Enum.join(Enum.sort(langs), ", ")})"}
    end
  end

  defp code(code) when is_binary(code) do
    cond do
      String.trim(code) == "" ->
        {:error, "code is empty"}

      byte_size(code) > @max_code_bytes ->
        {:error, "code is over #{div(@max_code_bytes, 1024)} KB"}

      true ->
        {:ok, code}
    end
  end

  defp code(nil), do: {:error, "missing code"}
  defp code(_), do: {:error, "code must be a string"}

  defp budget(nil, defaults), do: {:ok, defaults}

  defp budget(b, defaults) when is_map(b) do
    with :ok <- known_fields(b, @budget_fields) do
      Enum.reduce_while([:wall_s, :out_kb, :mem_mb], {:ok, defaults}, fn key, {:ok, acc} ->
        case b[Atom.to_string(key)] do
          nil ->
            {:cont, {:ok, acc}}

          n when is_integer(n) and n >= 1 and n <= :erlang.map_get(key, @limits) ->
            {:cont, {:ok, Map.put(acc, key, n)}}

          _ ->
            {:halt, {:error, "budget.#{key} must be an integer 1-#{@limits[key]}"}}
        end
      end)
    end
  end

  defp budget(_, _defaults), do: {:error, "budget must be an object"}

  defp leases(nil), do: {:ok, []}

  defp leases(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn lease, {:ok, acc} ->
      case lease_path(lease) do
        {:ok, path} -> {:cont, {:ok, acc ++ [path]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp leases(_), do: {:error, "leases must be a list of paths"}

  # Relative, inside the project, never into .universe/. Globs arrive in M3.
  defp lease_path(lease) when is_binary(lease) and lease != "" do
    parts = Path.split(lease)

    cond do
      Path.type(lease) != :relative ->
        {:error, "lease #{inspect(lease)} must be relative to the project"}

      ".." in parts ->
        {:error, "lease #{inspect(lease)} may not contain .."}

      String.contains?(lease, ["*", "?", "["]) ->
        {:error, "lease #{inspect(lease)}: globs are not supported yet"}

      hd(parts) == ".universe" ->
        {:error, "lease #{inspect(lease)}: .universe/ is off limits"}

      true ->
        {:ok, lease |> Path.join(".") |> Path.expand("/") |> Path.relative_to("/")}
    end
  end

  defp lease_path(_), do: {:error, "each lease must be a non-empty path string"}

  defp after_refs(nil, _nested?), do: {:ok, []}
  defp after_refs(_refs, true), do: {:error, "then steps can't have after"}

  defp after_refs(refs, false) when is_list(refs) do
    if Enum.all?(refs, &is_binary/1),
      do: {:ok, Enum.uniq(refs)},
      else: {:error, "after must be a list of labels or #ids"}
  end

  defp after_refs(_, _), do: {:error, "after must be a list of labels or #ids"}

  defp then_steps(nil), do: {:ok, []}

  defp then_steps(steps) when is_list(steps) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, acc} ->
      case normalize(step, true) do
        {:ok, d} ->
          {:cont, {:ok, acc ++ [d]}}

        {:error, %{reason: reason} = r} ->
          {:halt, {:error, "then step #{r.label || "?"}: #{reason}"}}
      end
    end)
  end

  defp then_steps(_), do: {:error, "then must be a list of run directives"}

  defp quiet(nil), do: {:ok, false}
  defp quiet(q) when is_boolean(q), do: {:ok, q}
  defp quiet(_), do: {:error, "quiet must be true or false"}

  defp target(t) when is_binary(t) and t != "", do: {:ok, t}
  defp target(_), do: {:error, "needs a target (#id or label)"}

  ## Batch rules

  defp all_labels(d), do: [d.label | Enum.flat_map(Map.get(d, :then, []), &all_labels/1)]

  defp reject_duplicates(ok) do
    counts = ok |> Enum.flat_map(&all_labels/1) |> Enum.reject(&is_nil/1) |> Enum.frequencies()
    dups = for {label, n} <- counts, n > 1, into: MapSet.new(), do: label

    Enum.split_with(ok, fn d -> not Enum.any?(all_labels(d), &MapSet.member?(dups, &1)) end)
    |> then(fn {keep, drop} ->
      {keep,
       Enum.map(drop, fn d ->
         dup = Enum.find(all_labels(d), &MapSet.member?(dups, &1))
         reject(d.label, d.op, "duplicate label #{dup}")
       end)}
    end)
  end

  defp check_after_refs(ok, resolve, gone) do
    # Only run/serve/call become workers you can wait on. kill and reply take
    # effect at once and have no ID to settle.
    top = for(d <- ok, d.op in ["run", "serve", "call"], d.label, into: MapSet.new(), do: d.label)
    control = for(d <- ok, d.op in ["kill", "reply"], d.label, into: MapSet.new(), do: d.label)

    nested =
      ok
      |> Enum.flat_map(&(&1 |> Map.get(:then, []) |> Enum.flat_map(fn t -> all_labels(t) end)))
      |> MapSet.new()

    Enum.reduce(ok, {[], []}, fn d, {keep, drop} ->
      bad =
        Enum.find_value(Map.get(d, :after, []), fn ref ->
          cond do
            MapSet.member?(top, ref) ->
              nil

            MapSet.member?(control, ref) ->
              "after #{ref}: #{op_of(ok, ref)} takes effect at once; wait on its target instead"

            MapSet.member?(gone, ref) ->
              nil

            MapSet.member?(nested, ref) ->
              "after #{ref}: then steps can't be waited on; use their parent"

            resolve.(ref) != :error ->
              nil

            match?({:ok, _}, parse_id(ref)) ->
              "after #{ref}: no such worker"

            true ->
              "after #{ref}: unknown label"
          end
        end)

      if bad, do: {keep, drop ++ [reject(d.label, d.op, bad)]}, else: {keep ++ [d], drop}
    end)
  end

  defp reject_cycles(ok) do
    by_label = Map.new(ok, &{&1.label, &1})

    edges =
      Map.new(ok, fn d ->
        {d.label, Enum.filter(Map.get(d, :after, []), &Map.has_key?(by_label, &1))}
      end)

    cyclic =
      Enum.reduce(ok, MapSet.new(), fn d, acc ->
        case find_cycle(d.label, edges, [d.label]) do
          nil -> acc
          path -> MapSet.union(acc, MapSet.new(path))
        end
      end)

    Enum.split_with(ok, &(not MapSet.member?(cyclic, &1.label)))
    |> then(fn {keep, drop} ->
      {keep, Enum.map(drop, &reject(&1.label, &1.op, "after cycle involving #{&1.label}"))}
    end)
  end

  defp find_cycle(start, edges, [current | _] = path) do
    Enum.find_value(Map.get(edges, current, []), fn next ->
      cond do
        next == start -> Enum.reverse([next | path])
        next in path -> nil
        true -> find_cycle(start, edges, [next | path])
      end
    end)
  end

  # Anything waiting on a rejected label in this batch is rejected too.
  defp propagate(ok, rejected) do
    gone = rejected |> Enum.map(& &1.label) |> Enum.reject(&is_nil/1) |> MapSet.new()

    case Enum.split_with(ok, fn d ->
           not Enum.any?(Map.get(d, :after, []), &MapSet.member?(gone, &1))
         end) do
      {keep, []} ->
        {keep, []}

      {keep, drop} ->
        new =
          Enum.map(drop, fn d ->
            dep = Enum.find(d.after, &MapSet.member?(gone, &1))
            reject(d.label, d.op, "depends on rejected #{dep}")
          end)

        {keep2, more} = propagate(keep, rejected ++ new)
        {keep2, new ++ more}
    end
  end

  defp op_of(directives, label) do
    case Enum.find(directives, &(&1.label == label)),
      do: (
        %{op: op} -> op
        _ -> "it"
      )
  end

  defp reject(label, op, reason), do: %{label: label, op: op, reason: reason}

  defp plural([_]), do: ""
  defp plural(_), do: "s"
end
