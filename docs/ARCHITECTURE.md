# Universe architecture

Universe is one OTP application per project folder. A coding-agent CLI (the
"model", for example Claude Code) talks to it over MCP with two tools, `tick`
and `inspect`. Everything the model asks for runs as a **worker**: a
GenServer in the daemon that owns one sandboxed OS process tree. Every step
is appended to an **event log**, which also feeds the web observer.

The diagrams below render on GitHub. Live versions of the same pictures are
in the observer:

- `/system`: this supervision tree, live, with each process's role, queue,
  memory and activity, and every worker's OS processes
- `/flow`: who talks to whom as a graph; edges animate as messages cross
- `/timeline/:tick`: one tick's flow as a sequence diagram
- `/` (Now): agents, services, running work and every event as it happens
- `/dashboard`: Phoenix LiveDashboard (generic processes, ports, ETS)

## 1. Supervision tree

Rounded boxes are supervisors (with their strategy), plain boxes are
GenServers, stadiums are processes started on demand, and the dotted part
is outside the BEAM (OS processes).

```mermaid
flowchart TD
  App(["Universe.Supervisor<br/>one_for_one"])

  App --> Tel(["UniverseWeb.Telemetry<br/>supervisor"])
  App --> PubSub["Phoenix.PubSub<br/>Universe.PubSub"]
  App --> Lock["Universe.Lock<br/>GenServer · one daemon per folder"]
  App --> Log["Universe.EventLog<br/>GenServer · JSONL + ETS + broadcast"]
  App --> Reg["Registry<br/>Universe.Registry · worker id → pid"]
  App --> Ids["Universe.Ids<br/>GenServer · worker and tick numbers"]
  App --> TaskSup(["Universe.TaskSup<br/>Task.Supervisor"])
  App --> ConnSup(["Universe.SDK.ConnSup<br/>DynamicSupervisor"])
  App --> Listener["Universe.SDK.Listener<br/>GenServer · Unix socket"]
  App --> Runtime(["Universe.Runtime<br/>rest_for_one"])
  App --> GC["Universe.GC<br/>GenServer · idle TTL, memory budgets, pruning"]
  App --> MCP(["Universe.MCP.Server<br/>Anubis · tick, inspect"])
  App --> Endpoint(["UniverseWeb.Endpoint<br/>Bandit · LiveView · /mcp"])

  Runtime --> Services["Universe.Services<br/>GenServer · live services, SDK tokens"]
  Runtime --> Tick["Universe.Tick<br/>GenServer · the kernel"]
  Runtime --> WorkerSup(["Universe.WorkerSup<br/>DynamicSupervisor"])

  TaskSup --> CallTask(["Task per call directive"])
  ConnSup --> Conn(["Universe.SDK.Conn<br/>GenServer per SDK connection"])
  Listener -.->|"acceptor starts one per connection"| Conn
  WorkerSup --> Worker(["Universe.Worker<br/>GenServer per worker ID"])

  subgraph OS["OS processes, one process group per worker"]
    Launcher["universe_run<br/>launcher · own session"]
    Sandbox["sandbox-exec<br/>Seatbelt profile"]
    Code["python3 · bash · elixir<br/>the worker's code with U preloaded"]
    Bridge["python3 agent_bridge.py<br/>agent workers only"]
    Claude["claude -p --restricted<br/>one session per agent"]
    Launcher --> Sandbox --> Code
    Launcher --> Bridge --> Claude
  end

  Worker -->|"Erlang port · packet 4"| Launcher
```

Why the shape:

- **`Runtime` is `rest_for_one`.** If `Tick` crashes, `WorkerSup` restarts
  too, so no worker outlives the state that tracks it. The new `Tick`
  rebuilds its worker table from the event log; workers that were running
  are recorded as `killed · lost: Universe restarted`.
- **One GenServer per worker, one OS process group per GenServer.** The
  launcher puts the code in its own session and kills the whole group when
  the code exits, when told to (`K`), or when the port closes because the
  GenServer died. Workers are `:temporary`: `Tick` decides about restarts
  (services: at most 3 in 60 s), not the supervisor.
- **SDK connections are separate GenServers** under `ConnSup`, so a hung or
  chatty worker can't block `Tick`. A connection proves which worker it is
  with the token it was given in `UNIVERSE_TOKEN`.
- **Agent workers** run the bridge instead of the Seatbelt sandbox, because
  `claude` needs your login and the Claude API. The bridge runs
  `claude --restricted`: no code-running tools, file tools confined to the
  project, writes only to leased paths, `.universe/` denied.

## 2. A tick, end to end

```mermaid
sequenceDiagram
  autonumber
  participant M as Model (Claude Code)
  participant X as MCP server (Anubis)
  participant T as Tick (GenServer)
  participant WS as WorkerSup
  participant W as Worker 5 (GenServer)
  participant L as universe_run + sandbox
  participant C as SDK Conn (GenServer)
  participant E as EventLog

  M->>X: tools/call tick {directives, wait}
  X->>T: GenServer.call {:tick, args}
  T->>E: tick_in
  T->>T: validate, place, schedule
  T->>WS: start_child(Worker)
  WS->>W: init, then start
  W->>E: spawn
  W->>L: Port.open (argv, env, profile)
  L-->>W: P pid
  L->>C: code connects to the SDK socket
  C->>E: put, get, progress, call
  L-->>W: O / E output packets
  W->>E: stdout, stderr
  L-->>W: X exit code, signal
  W->>E: exit
  W->>T: {:worker_exit, id, summary}
  T->>T: wake rule fires (settled, attention or timeout)
  T->>E: tick_out
  T-->>X: digest text
  X-->>M: tool result
```

The model never waits longer than its `wait.timeout_s` (90 s at most).
Workers keep running after the digest; their later events are reported by
the next tick.

## 3. Calling a service

A service is a worker whose code called `U.serve(name, fns)`. There are two
ways to call it, and both end up as an `invoke` line on the service's own
SDK connection, handed over one at a time.

```mermaid
sequenceDiagram
  participant M as Model
  participant T as Tick
  participant K as Task (TaskSup)
  participant W as Worker 6 code
  participant C6 as Conn of 6
  participant S as Services
  participant C5 as Conn of service 5
  participant P as Service 5 code

  Note over M,P: a call directive from the model
  M->>T: call {service: pg, fn: query}
  T->>K: async_nolink
  K->>S: Services.invoke(pg, query)
  S->>C5: GenServer.call {:invoke, fn, args, timeout}
  C5->>P: invoke line (cid, fn, args, timeout_ms)
  P-->>C5: result line
  C5-->>K: {:ok, value}
  K-->>T: result → inline, or a handle if large

  Note over M,P: U.call from another worker's code
  W->>C6: call {service: pg, fn: query}
  C6->>S: Services.invoke
  S->>C5: {:invoke, ...}
  C5->>P: invoke line
  P-->>C5: result line
  C5-->>C6: {:ok, value}
  C6-->>W: reply line
```

Events: a call directive logs `call` with `via: tick` and its result in the
call ID's `exit`; a `U.call` logs `call` with `via: sdk` and `call_done` on
the caller's ID.

## 4. Agent workers

```mermaid
sequenceDiagram
  participant M as Model
  participant T as Tick
  participant C as Conn of agent 9
  participant B as agent_bridge.py
  participant CL as claude session

  M->>T: serve {agent: {purpose, model, tools, pool}}
  T->>B: start worker (bridge, no Seatbelt)
  B->>CL: claude -p --input-format stream-json --restricted ...
  B->>C: U.serve(name, {task})
  M->>T: call {service: pool or name, prompt}
  T->>C: invoke task(prompt) on a free member
  C->>B: invoke line
  B->>CL: user message
  CL-->>B: result
  alt the answer starts with QUESTION:
    B->>T: U.ask(question) → worker shows as asking
    M->>T: reply {target: 9, text}
    T-->>B: answer
    B->>CL: Answer from the orchestrator: ...
    CL-->>B: result
  end
  B-->>C: result line
  C-->>T: answer → the call's result
```

The session ID is saved in `.universe/agents/<name>.json`, so serving the
same agent again (after a kill, a crash or a daemon restart) resumes its
conversation. A task past its call's deadline is interrupted with a
stream-json `interrupt` control request.

## 5. Events and the observer

```mermaid
flowchart LR
  subgraph Writers
    Tick
    Worker
    Conn["SDK Conn"]
    GC
    Hooks["Hook endpoints"]
  end

  Writers -->|"EventLog.append"| Log["EventLog<br/>redact secrets, seq"]
  Log --> File[(".universe/log/events.jsonl")]
  Log --> ETS[("ETS table<br/>queries by tick, id, type")]
  Log -->|"PubSub events topic"| Views["LiveViews<br/>Now · Timeline · Flow · Workers · Handles"]
  Log -->|"wake waiters"| Tick
  File -->|"on boot"| Log
  File -->|"offline"| Replay["/replay"]
```

## 6. Who talks to whom

| From | To | How | What |
|---|---|---|---|
| Model | MCP server | HTTP, bearer token | `tick`, `inspect` |
| MCP server | `Tick` | `GenServer.call` via `Universe.API` | directives and wait; `inspect` reads the event log, handles and `Tick.snapshot` |
| `Tick` | `WorkerSup` | `DynamicSupervisor.start_child` | new workers |
| `Tick` | `TaskSup` | `Task.Supervisor.async_nolink` | call directives |
| `Worker` | launcher | Erlang port, `{packet, 4}` | start, `K` kill; back: `P` pid, `O`/`E` output, `X` exit |
| `Worker` | `Tick` | message `{:worker_exit, ...}` | summary when the process ends |
| worker code | `Listener` → `Conn` | Unix socket, JSON lines | `put`, `get`, `progress`, `ask`, `call`, `serve` |
| `Conn` | `Tick` | `GenServer.call` | `ask` (blocks for the model's reply), `service_ready` |
| `Conn`, call `Task` | `Services` → service `Conn` | `GenServer.call {:invoke, ...}` | a service function call |
| `GC` | `Tick`, `Worker` | casts | stop idle services, kill over-budget groups |
| everyone | `EventLog` | `append` | one event per step |
| `EventLog` | LiveViews, `Tick` | PubSub | live pages; tick wake-ups |

## 7. Files

```
.universe/
  port, token            how the CLI reaches this daemon (token mode 0600)
  log/events.jsonl       every event, append-only (redacted)
  runs/<id>/             a worker's code, stdout, stderr, sandbox.sb, token
  handles/<id>/          stored values: <name>.json + <name>.meta.json
  agents/<name>.json     an agent's saved session ID (+ .usage.jsonl)
  secrets/<service>.env  per-service secrets, never readable by workers
  sdk.sock               the SDK socket (or $TMPDIR/universe-<hash>.sock)
```
