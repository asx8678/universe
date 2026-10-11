defmodule Universe.MCP.Server do
  @moduledoc """
  MCP server exposing exactly two tools, `tick` and `inspect`.

  Tool definitions are fixed structs returned from `server_tools/2` in a fixed
  order, so `tools/list` is byte-identical across calls (prompt-cache friendly).

  Input schemas are deliberately loose: Anubis turns schema failures into MCP
  errors, but a bad directive must come back as a `rejected` digest line, so
  validation happens in `Universe.API`, not here.

  Replies carry text only. Claude Code shows the model `structuredContent`
  instead of the text whenever it is present, so the structured view of a tick
  lives in the event log (`tick_out`), not in the MCP result.
  """

  use Anubis.Server,
    name: "universe",
    version: "0.1.0",
    capabilities: [:tools],
    # Claude Code 2.1.296 probes 2026-07-28 (server/discover) first, then falls back.
    protocol_versions: ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]

  alias Anubis.Server.Component.Tool
  alias Anubis.Server.Response

  @tick_description """
  Send directives to Universe and wait for results. Each job is a worker \
  with an ID (#1, #2, ...); jobs in one batch run in parallel. Returns a \
  digest line per changed worker, failed first; bad directives come back \
  rejected; no directives just waits. Workers run in the project root, \
  read-only except their leases, with no network unless a serve lists \
  "network" hosts. A held lease rejects a directive unless it has "after" \
  (then it waits).

  Build helpers that pay off: services for what you use more than once (DB, \
  API, index), agents for judgment work with the services they need; serve \
  and task them in one tick.

  Ops (each needs a unique "label"):
  run: one-shot code. {"op":"run","label":"l","lang":"python|bash|elixir", \
  "code":"...","budget":{"wall_s":120,"out_kb":256,"mem_mb":2048}, \
  "leases":["paths/it/writes"],"after":["label or #id"], \
  "then":[runs started when it exits 0],"quiet":true}.
  serve: a long-lived service; its code calls U.serve(name,{fn: callable},desc). \
  {"op":"serve","label":"pg","lang":"python","code":"...", \
  "network":["host:port"],"ttl_idle_s":900}.
  call: {"op":"call","label":"q","service":"pg","fn":"query","args":{...}, \
  "timeout_s":60}. Large results become a handle.
  agent: a serve with "agent" instead of code, a Claude session that takes \
  tasks: {"op":"serve","label":"rev","agent":{"purpose":"system prompt", \
  "model":"haiku","tools":["Read","Grep"],"services":["pg"], \
  "pool":"reviewers"}}; task it: {"op":"call","label":"r1","service": \
  "rev or a pool","prompt":"..."}. It can't run code; its services are its tools.
  steer: add to a busy agent's task. {"op":"steer","target":"rev or r1", \
  "text":"...","interrupt":false}.
  kill: {"op":"kill","target":"#5 or label"}.
  reply: answer an asking worker, or the task of an asking agent. \
  {"op":"reply","target":"#9","text":"..."}.

  In code U is preloaded (python, elixir): U.put(name,value)->handle, \
  U.get(h), U.call(service,fn,args), U.progress(text), U.ask(q). Pass big \
  data as handles. wait: {"until":"all|any","ids":["#5","label"], \
  "timeout_s":60} (max 90).
  """

  @inspect_description """
  Look closer at something a digest referenced. target is "manifest" (live \
  services, saved tools, leases, live IDs), "#<id>" (worker card, code, output \
  tail), "h:<id>/<name>" (handle preview) or "t<n>" (all events of a tick). \
  Paged with offset/limit; grep filters lines.\
  """

  # Claude Code defers MCP tools behind tool search unless marked.
  @always_load %{"anthropic/alwaysLoad" => true}

  @tools [
    %Tool{
      name: "tick",
      title: "tick",
      description: @tick_description,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "directives" => %{
            "type" => "array",
            "items" => %{"type" => "object"},
            "description" => "Directives to run this tick, each with an op and a unique label."
          },
          "wait" => %{
            "type" => "object",
            "description" =>
              ~s(When to return: {"until": "any"|"all", "ids": ["#5", "label"], "timeout_s": 60}.)
          },
          "since" => %{
            "type" => "integer",
            "description" => "Event cursor to report from. Defaults to the last cursor returned."
          }
        }
      },
      meta: @always_load,
      validate_input: &__MODULE__.accept/1
    },
    %Tool{
      name: "inspect",
      title: "inspect",
      description: @inspect_description,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "target" => %{"type" => "string"},
          "offset" => %{"type" => "integer"},
          "limit" => %{"type" => "integer"},
          "grep" => %{"type" => "string"}
        },
        "required" => ["target"]
      },
      meta: @always_load,
      validate_input: &__MODULE__.accept/1
    }
  ]

  @doc false
  def accept(params) when is_map(params), do: {:ok, params}
  def accept(_), do: {:ok, %{}}

  @doc "The tool list, in its fixed order."
  def tools, do: @tools

  @impl true
  def init(_client_info, frame), do: {:ok, frame}

  @impl true
  def server_tools(_tools, _frame), do: @tools

  @impl true
  def handle_tool_call("tick", args, frame), do: reply(Universe.API.tick(args), frame)
  def handle_tool_call("inspect", args, frame), do: reply(Universe.API.inspect(args), frame)

  defp reply(%{text: text}, frame), do: {:reply, Response.text(Response.tool(), text), frame}
end
