# Universe: implementation plan and tasks

Source: "Universe — Architecture & Action Plan" (Oct 10, 2026). This file turns that design into tasks you can tick off. The design doc still defines *what* to build. This file covers *in what order* and *how we know it works*.

---

## 0. Environment check (done Oct 10, 2026)

| Design assumes | This machine | Impact |
|---|---|---|
| Linux: `box`, mounts, `prlimit`, cgroups, `/proc` | **macOS (Darwin)**, no `box`, no `prlimit`, `/usr/bin/sandbox-exec` present | Changes the M1 runner and the M3 safety work. See Decision 1 |
| Elixir 1.19 / OTP 28 | Elixir 1.20.4 / OTP 29 | Check that phoenix, live_view, bandit, anubis_mcp and muontrap resolve and compile at `deps.get` |
| Claude Code (version unknown) | 2.1.296 | Record the MCP protocol version it sends (spike S1) |
| Kiro CLI | not installed | The Kiro task is **blocked**. Moved out of M3 |
| MuonTrap | cgroups only work on Linux; 2.x needs cgroup v2 | Check that the C port builds and kills process trees on macOS (spike S5). Fallback: Port plus a kill wrapper |
| Repo | holds only `README.md` | `mix phx.new` into an existing directory asks for confirmation. Run it as `mix phx.new . --app universe --no-ecto --no-mailer` |

### M0 findings (Oct 10, 2026)

- **Protocol:** Claude Code 2.1.296 sends `server/discover` with `MCP-Protocol-Version: 2026-07-28` first, then falls back to `initialize` with 2025-11-25 if that fails. Stateless requests also carry `Mcp-Method` and `Mcp-Name` headers.
- **Anubis 2.1.0 (Oct 5) supports 2026-07-28**, but only after you opt in with `protocol_versions: [...]` in `use Anubis.Server`. With that set, the trace is `server/discover` → `tools/list` → `tools/call`, with no sessions.
- **`structuredContent` replaces the text.** When a result has `structuredContent`, Claude Code shows the model that JSON instead of the `content` text. So replies are text only, and the structured view goes into the `tick_out` event.
- **Tools are deferred.** On turn 1 the model needed ToolSearch (`select:mcp__universe__tick`) before it could call `tick`. That costs 1 extra turn per session.
- **Anubis timeouts:** both the plug and the server child default to a 30 s `request_timeout`. Both are set to 120 s so 90 s waits fit.
- **Anubis server start:** it doesn't start when Phoenix isn't serving (tests), so it is started with `transport: {:streamable_http, start: true}`.
- **MuonTrap 2.0.1** builds on macOS. Killing the whole process tree is still untested (S5).
- Anubis turns schema failures into MCP errors, so the tool schemas are loose and validation happens in `Universe.API`.

---

## 1. Decisions

### M1 findings (Oct 10, 2026)

- **Process ownership:** `priv/bin/universe_run` (C, built by elixir_make) replaces MuonTrap. The child gets its own session, and the launcher SIGKILLs the whole group when the main process exits, on `K` (TERM, then KILL after 2 s) or when stdin hits EOF (the BEAM is gone). stdout and stderr are framed separately over `{packet, 4}`. **Known gap:** a process that calls `setsid()` itself escapes the group. Full containment needs OS-level process tracking (a later adapter).
- **Clean environment:** workers start through `env -i` with only PATH, HOME=run dir, TMPDIR=run dir, LANG and `UNIVERSE_*`. Daemon secrets never leak into snippets.
- **The profile allows `mach-lookup` broadly** (many binaries need it). That is an IPC surface to narrow in M3.
- **Acceptance (claude -p, Bash disallowed):** 5 checks ran in one tick in parallel. The model fixed the failed write with a lease in one follow-up tick and needed no `inspect`. That took 3 turns.
- **Claude Code registration** now uses `claude mcp add-json` with `"alwaysLoad": true` (tools load on turn 1, so no ToolSearch) and `"timeout": 120000` (the default per-request timer is 60 s, shorter than a 90 s tick). The tools also carry `_meta: {"anthropic/alwaysLoad": true}`.
- The tick tool description now lists the directive fields (776 chars), so the model can work before the skill exists.
- Event types added beyond the design: `queued` and `rejected`.

### M4 result (Oct 10, 2026): NO-GO under the pre-registered rule

18 runs (3 tasks × 2 setups × 3), all graded PASS. Universe lost every task on
every metric: end-of-run context +9 to +11%, total tokens 1.5–2×, slower, more
turns. Full table in `bench/RESULTS.md`. Why:

- **Fixed overhead dominates at this scale.** Turn 1 already carries ~26k tokens
  (Claude Code's system prompt) in both setups; Universe adds ~1.5k. Task content
  is only 2–7k on top, so the "≥50% less end-of-run context" bar was out of reach
  for these fixtures whatever the design.
- **Universe spends extra turns**: one to load the skill, one or two `inspect`
  round-trips to read output the digest only summarised. Each turn re-sends ~30k.
- **The fixtures are wide in count, tiny in data.** One shell loop handles all 20
  items, so neither handles nor parallel workers have anything to save.

Per the README's no-go clause: keep services + SDK as a plain MCP server, drop
tick batching — or, as a *separate* experiment with its own thresholds set in
advance, test the original thesis at a scale where it can matter (raw outputs
far larger than the context, slow independent steps). Cheap fixes either way:
skip the skill-load turn (the tick description now carries the essentials) and
put more of what the model needs in digest lines so it calls `inspect` less.

### M2 + M3 findings (Oct 10, 2026)

- **Incident — a process-killer almost shipped.** An experimental launcher sweep (`--probe`) tried to find processes that left a worker's group by their macOS sandbox identity (`sandbox_check` for write access to a per-run probe file). The check also matched *unrelated* sandboxed processes whose profile allowed writing that directory (tests used a dir under the repo; the release used `/private/tmp`). It ran on every worker exit from when `--probe` landed until it was disabled. The one surviving test log shows **45 kills in a single full-suite run** (summed `escaped_killed`); the probe was live across several full runs plus ~16 isolation-only runs whose logs the test alias then wiped, so the exact total is unknown — **at least 45 per full run, several runs**, plus **18 in one release smoke test**. What it could have hit: any sandboxed process on the machine (system XPC/helpers, possibly app processes). The sweep was **removed entirely** from `c_src/universe_run.c`, not just disabled. The `setsid`/daemonise escape is back to a **known gap**, with both tests tagged `:known_gap`.
- **`sandbox_check` identity is unusable** for "is this my process": it returns allowed for any process whose profile permits the operation, not just descendants.
- **The env-marker approach (`ps -axE`) also failed**: a sandboxed child's environment isn't visible to `ps`, so the marker couldn't be read.
- **Seatbelt can't restrict by remote host.** It names only `localhost` or `*`, so a service's `network: ["db:5432"]` opens port 5432 to any host. Real host restriction needs an outbound proxy (deferred).
- **The SDK socket** lives at `.universe/sdk.sock`, or `$TMPDIR/universe-<hash>.sock` when the project path would exceed macOS's 104-byte socket-path limit. Workers authenticate with a per-worker token written to their run dir.
- **Tool description must list every op.** First M2 acceptance run: the model tried `op:"service"` and hand-rolled a reader with `run`, because the tick description documented only run/kill/wait and the skill body didn't load headlessly. Fixed: the description now covers run/serve/call/kill/reply and the `U` SDK (1,503 chars). After the fix the model used serve+call and got a handle back.
- **Handle preview crash (fixed).** A `{columns, rows}` table whose `rows` were objects (not arrays) crashed `inspect` ("Internal error"). The model produced exactly that. `Handles.table/1` now aligns object-rows to the columns; regression test added.
- **Release:** `mix release` with a `universectl` front end (`init`/`up`/`manifest`). Distributed Erlang is disabled (`RELEASE_DISTRIBUTION=none`) — the design forbids exposing it, and it also let two daemons clash on the node name. Prod config is loopback-only http with a per-boot random cookie secret.
- **SQLite (and anything that resolves real paths) failed in the sandbox — fixed.** Not lock files: the profile denied `stat` on the project's ancestor directories under `$HOME`, which `realpath`-style resolution needs. Even `immutable=1` with `uri=True` failed. The profile now allows `file-read-metadata` on the exact ancestor directories only (no listing, no contents); `$HOME` stays unreadable. This cost the model ~10 turns in each acceptance run.

### Decision 1: isolation runs on macOS first, behind an adapter (recommended default)
- Add the behaviour `Universe.Isolation` with `wrap(cmd, args, profile, opts) :: {cmd, args, env}` and `limits(profile)`.
- Adapters:
  - `Universe.Isolation.SandboxExec` (**v1 default on macOS**). It generates a Seatbelt `.sb` profile per run into `.universe/runs/<id>/sandbox.sb`:
    - snippet: `(deny default)`, allow process-exec and file-read for the project and toolchains, allow `file-write*` only on leased subpaths, `.universe/runs/<id>/` and the SDK socket, `(deny network*)` except the Unix socket.
    - service: the same, plus `(allow network-outbound (remote ip "<host>:<port>"))` for each allowed host.
  - `Universe.Isolation.Box` (Linux, later). `box` is probably prologic/box: Linux namespaces plus cgroups.
  - Option to check in spike S6: **Anthropic `srt` (sandbox-runtime)**. It wraps sandbox-exec on macOS and bubblewrap on Linux, and it has proxy-based per-domain network filtering. One adapter could then cover both operating systems.
- Memory budget: on macOS `setrlimit(RLIMIT_AS)` is not enforced, so the worker polls RSS (`ps -o rss= -p`) every 1 s and kills on overrun, with status `budget`. `prlimit`/cgroups go only in the Linux adapter.
- `sandbox-exec` is marked deprecated by Apple but still ships and is used by Claude Code and srt. Accept that for v1.
- Done-when tests are written without naming the adapter ("a write outside the lease fails"), so the escape suite runs against any adapter.

### Decision 2: Anubis or our own stateless Plug — **decided: Anubis 2.1** (it serves 2026-07-28 once opted in)
- Start with Anubis (`anubis_mcp ~> 2.1`). If spike S1 shows Claude Code sends 2026-07-28 and Anubis rejects it or mishandles it, write `Universe.MCP.Plug`: JSON-RPC over POST with `server/discover`, `initialize`, `tools/list` and `tools/call`.

### Decision 3: go/no-go thresholds (fixed before M4 starts)
- Write them into `bench/README.md` before the first run. The starting proposal is in the design doc.

---

## 2. Day-1 spikes (before M1 code; each is at most 2 h)

- [x] **S1 Protocol version.** Done: 2026-07-28 (see M0 findings). Use a stub Plug that logs raw requests, run `claude mcp add` against it, and record the `protocolVersion` and headers that Claude Code 2.1.296 sends.
- [x] **S2 Anubis fit.** Done: yes, with the `protocol_versions` opt-in. Does Anubis 2.1 accept S1's handshake, and does it serve `tools/call` without a session? The answer settles Decision 2.
- [ ] **S3 Local-scope approval.** (Headless `claude -p` runs need no approval; an interactive session is still untested.) Does a server registered with `-s local` need a one-time approval per project? Does the `settings.local.json` allow-list stop the per-call prompts?
- [x] **S4 Tool deferral.** Confirmed: the tools are deferred. Are `mcp__universe__tick` and `mcp__universe__inspect` loaded on turn 1, or deferred behind ToolSearch? (This session showed MCP tools being deferred, so the risk is real.) Mitigation either way: name both full tool names in SKILL.md and CLAUDE.md.
- [x] **S5 MuonTrap on macOS.** Run `MuonTrap.Daemon` with a child that forks grandchildren, kill the GenServer, and check with `pgrep` that the whole tree is gone. — Done: **MuonTrap fails.** It kills only the direct child, so grandchildren survive. Replaced by `c_src/universe_run.c` (own session, group kill on exit, kill or port close; tested).
- [x] **S6 Sandbox.** Hand-write a snippet `.sb` and test it: writes in the lease work, writes elsewhere fail, a symlink escape fails, `curl` fails, and the Unix socket works. Compare with `srt` on the same cases. — Done: the hand-written profile passes the whole matrix (lease writes yes; src, /tmp, symlink, `..`, hardlink, token, `$HOME` and network no). srt not compared yet.
- [x] **S7 Cold start.** Measure the start time of `elixir main.exs` and `python3 -I main.py` inside the sandbox. If Elixir is over about 1.5 s, add a pooled runner to the backlog. — Done: inside the sandbox, python3 takes 0.02 s, elixir 0.15 s, bash 0.01 s. No pool needed.

The Claude Code questions (S1, S3, S4) can also go to the `claude-code-guide` agent before running anything.

---

## 3. Milestones

Each milestone lists its tasks (with paths), its automated tests (ExUnit), its manual acceptance steps (with Claude Code), and its done-when test.

### M0: skeleton and handshake (1–2 days)

**Tasks**
- [x] `mix phx.new . --app universe --no-ecto --no-mailer`. Bind the endpoint to `{127, 0, 0, 1}` in `config/*.exs`
- [x] `.gitignore`: add `.universe/`
- [x] `lib/universe/paths.ex`: resolve `.universe/{port,token,log,runs,handles,tools,secrets}` under the **target project root** (`--dir` / `UNIVERSE_PROJECT`, default cwd), never the universe repo's own directory
- [x] Launcher (the dev part is done): for now, `mix universe.up --dir <project>` (and `universe.init --dir`). Before M4, a `mix release` with `bin/universe init|up` so other folders can start it (an escript can't carry the Phoenix assets cleanly)
- [x] Create `../universe-playground/`. All manual acceptance runs there, never in the universe repo
- [x] `lib/mix/tasks/universe.init.ex`: pick a free port once and keep it, write a random token (32 bytes, base64url, file mode 0600), run `claude mcp add --transport http universe http://127.0.0.1:<port>/mcp -s local -H "Authorization: Bearer <token>"`, merge `.claude/settings.local.json` (allow both tools), update `.gitignore`. Running it twice must change nothing
- [x] `lib/mix/tasks/universe.up.ex`: read the port and start the endpoint
- [x] `lib/universe/api.ex`: `tick/2` and `inspect/2` return a fixed stub digest
- [x] `lib/universe/mcp/server.ex`: an Anubis server with the two tools in a fixed order with fixed descriptions (each under 2,048 chars)
- [x] `lib/universe_web/plugs/mcp_guard.ex`: bearer token check (constant-time compare), reject non-loopback peers, reject foreign `Origin` headers
- [x] Raw MCP request logging to `.universe/log/mcp_raw.jsonl` (M0 only, behind a config flag)

**ExUnit**
- `McpGuardTest`: missing or wrong token gives 401, foreign Origin gives 403, non-loopback `remote_ip` gives 403
- `UniverseInitTest`: running init twice keeps the port and token and leaves `.gitignore` and `settings.local.json` unchanged (the `claude` call is stubbed through `System.cmd`)
- `ToolsListTest`: tool order and descriptions match exactly, so the prompt cache can hit

**Manual:** `/mcp` shows universe as connected. Ask Claude to call `tick` and quote the result.
**Done when:** Claude Code calls `tick` and quotes the stub digest back. Record the S1 protocol version and settle Decision 2.

### M1: snippets, event log, tick loop (3–5 days)

**Tasks**
- [x] `Universe.Ids`: monotonic worker IDs and tick IDs, never reused. The high-water mark is saved to disk and restored at boot
- [x] `Universe.EventLog`: append JSONL (one writer process, `:file.write` plus periodic `:file.datasync`), ETS index by `seq`/`tick`/`id`, rebuilt from JSONL at boot, PubSub broadcast on the `events` topic
- [x] Secret redaction hook in `EventLog.append/1`: replace known secret values with `«redacted:name»`. It does nothing until M2 adds `.universe/secrets/*.env`
- [x] `Universe.Isolation` behaviour plus the `SandboxExec` adapter (snippet profile only)
- [x] `Universe.Worker` (GenServer, `:temporary` for snippets): write `runs/<id>/main.{py,sh}`, start through MuonTrap (or the fallback), stream stdout/stderr to files and events, wall-clock timer, per-stream output cap (the rest stays on disk), exit event
- [x] `Universe.WorkerSup` (DynamicSupervisor) and `Universe.Registry`
- [x] `Universe.Tick.Validator`: check schema per op, labels unique within the batch, labels in `after` resolve (in the batch or live IDs), **cycle detection** over the `after`/`then` graph, unknown ops and fields become `rejected` lines with a reason. Never raise an MCP error
- [x] `Universe.Tick` (GenServer): queue, label→ID map, start when `after` is satisfied, run `then` on exit 0 without waking the model, a failed dependency marks its dependents failed with reason `dep #n failed`
- [x] Wake rules: all watched IDs settled, OR a failed/asking worker has waited 20 s, OR `timeout_s` (clamped to 90). Record which rule fired in `tick_out`
- [x] Cursor semantics: `since` defaults to the last cursor returned. The digest covers IDs with events where `seq > since`
- [x] `Universe.Digest`: ordering (failed, asking, done, running), auto-acked results collapsed into one line, a cap of about 2,000 tokens (estimated as chars/4) with an overflow pointer to `inspect("t<n>")`, and `structuredContent` (cursor, per-ID status, handles)
- [x] `inspect` for `#id` (card, code, paged output tail, `grep`) and `t<n>` (that tick's events, paged under about 8,000 tokens)
- [x] `UniverseWeb.TimelineLive` (`/`): per tick, the directives sent, the digest returned, token estimates (labelled as estimates), wait time and the wake rule. Use LiveView streams

**ExUnit**
- `ValidatorTest`: duplicate label, unresolved `after`, an `after` cycle, a `then` cycle, unknown op, missing `code`, `timeout_s` > 90 clamped
- `TickChainTest`: A→then B runs B only when A exits 0. A failing marks B failed. `after` across directives in one batch
- `WakeRulesTest`: each of the three rules fires and is recorded (use a short test clock)
- `DigestTest`: ordering, the auto-ack collapse, 300 changed IDs truncated under the cap with an overflow pointer, a golden-file snapshot of the text format
- `EventLogTest`: append and reload rebuild the same ETS index. Redaction removes the secret value
- `WorkerTest`: exit codes, wall budget gives status `budget`, output past the cap is truncated in events but complete on disk
- `ParallelTest`: 5 snippets that each sleep 1 s finish in under 2 s total

**Manual:** ask Claude for 5 independent checks. It sends one tick, reads the digest and plans the next batch without calling `inspect`.
**Done when:** that works, and the timeline shows both directions with token estimates.

### M2: services, SDK, handles (4–6 days)

**Tasks**
- [x] `Universe.SDK.Listener`: a Unix socket at `.universe/sdk.sock` (mode 0600), newline-delimited JSON, every request authenticated by `UNIVERSE_ID` plus a per-worker `UNIVERSE_TOKEN`. On macOS, keep the socket path under 104 bytes (fall back to `$TMPDIR` plus a symlink when the project path is long)
- [x] SDK protocol, documented in `lib/universe/sdk/protocol.md`: `call`, `put`, `get`, `progress`, `ask`, `serve`, `fn_result` — done: `lib/universe/sdk/protocol.md`
- [x] `priv/sdk/universe.py`: standard library only (it runs under `-I`)
- [x] Service workers (`:transient`, at most 3 restarts in 60 s, then reported failed). `U.serve` registers the name, functions and description. The kernel routes `call` directives and `U.call` requests and enforces a timeout per call
- [x] Service sandbox profile: per-host network allow-list and `.universe/secrets/<name>.env` injected into that service only — host part is coarse: Seatbelt can only allow a port on every host
- [x] `Universe.Handles`: `h:<id>/<name>`, kinds table/json/text/file, stored on disk under `.universe/handles/`, previews (table: schema plus first 5 rows plus row count; json: top-level keys plus size; text: head; file: size plus mime) — file previews show size only, no mime type
- [x] `inspect("manifest")`: live services and descriptions, saved tools in `.universe/tools/`, open leases, live IDs. Also as plain text for the hook (`mix universe.manifest` plus a `GET /manifest.txt` route behind the guard) — the hook reads `GET /hooks/manifest`, not `/manifest.txt`; no mix task
- [x] `inspect("h:…")`: preview only
- [x] Elixir runner (`elixir main.exs` in its own BEAM, never distributed) and `priv/sdk/universe.exs`

**ExUnit**
- `SdkAuthTest`: a wrong token or ID is rejected, and one worker cannot `get` a handle without the matching token rules (decide whether handles are global or per-ID; the default is global read)
- `ServiceTest`: serve then call round-trip, the per-call timeout, restart intensity reaching failed
- `HandlesTest`: each kind's preview never exceeds N bytes
- `SdkPyTest`: run `universe.py` against a live listener (tagged `:integration`)

**Manual:** Claude writes a SQLite or Postgres reader service in one tick, then a later snippet calls `U.call("pg","query",…)` and `U.put`s the rows.
**Done when:** that works and only the handle preview ever shows up in the context.

### M3: safety and plugin (3–4 days)

**Tasks**
- [x] Leases (`Universe.Leases`): path and glob claims per ID, overlap check (glob against glob is done conservatively, by comparing prefixes), released on exit, rejected lines name the holder. They are enforced through the isolation adapter's writable paths — leases are path prefixes; globs are not accepted
- [x] Escape test suite `test/isolation/escape_test.exs`, run against the configured adapter: write outside the lease, symlink inside the lease pointing outside, `..` traversal, hardlink, writes to `/tmp` and `$HOME`, network from a snippet, network to a host the service did not allow, reading `.universe/token` and `.universe/secrets` (must be denied)
- [x] Budgets: wall clock (M1), output cap (M1), memory (RSS poller on macOS / prlimit on Linux) leading to `budget_hit` and status `budget`
- [x] `Universe.GC`: idle TTL (default 900 s), at most 20 live services (refuse the new one or reap the oldest idle one: pick one), prune run directories older than 7 days, a `gc` event for every stop — at the cap a new service is refused
- [x] Stop all: `Universe.API.stop_all/0`, a button on `/workers`, a `stop_all` event that the next digest reports
- [x] `/workers` and `/workers/:id` LiveViews (process tree, budget used, leases, live stdout/stderr, handles created) — no process tree view yet
- [x] `plugin/universe-plugin/`: `plugin.json`, `skills/universe/SKILL.md` (the draft from the doc, plus both full tool names), `reference.md` (full schemas plus 3 worked examples), `hooks/hooks.json`
- [x] Development hazard: once this hook exists, a daemon running in a folder takes Bash away from Claude sessions there. Never run `universe.up` inside the universe repo with the plugin loaded. Test in `../universe-playground` — followed: tests ran in scratch projects
- [x] `hooks/redirect-bash.sh`: exit 0 if `.universe/port` is missing or the daemon does not answer (curl with a 200 ms timeout), else print the redirect message to stderr and exit 2. Count redirects through a small event endpoint
- [x] `hooks/manifest.sh`: fetch `/manifest.txt` and print it. Stay silent and exit 0 when the daemon is not running
- [x] Add one line to the project `CLAUDE.md`: "All execution in this project goes through Universe (mcp__universe__tick, mcp__universe__inspect). Use the universe skill." — `universectl init` adds it
- [x] Test the plugin with `claude --plugin-dir ./plugin/universe-plugin`, then through a local marketplace — `--plugin-dir` tested in headless runs; `claude plugin validate` passes on the marketplace; installing through the marketplace not tested

**ExUnit**
- `LeasesTest`: overlap, release on exit, glob conservatism
- `EscapeTest` (above, tagged `:isolation`)
- `GCTest`: idle reap, cap, pruning (short test clock)
- Hook scripts: `bats` tests or ExUnit `System.cmd` tests with and without a daemon running

**Manual:** in a Claude session with the plugin, ask it to "run the tests". Bash is redirected and it uses `tick`. Start a service, go idle and see the reap in the next digest.
**Done when:** a write outside the lease fails, a Bash attempt is redirected to `tick`, and a forgotten service is reaped and reported.

### M4: benchmark (2–3 days)

**Tasks**
- [x] Settle Decision 3 (the thresholds) in `bench/README.md` **before** any run
- [x] `bench/fixtures/`: 20 modules or repos to summarize. A repo with 20 independent edits and a test suite. A SQLite database with 20 checks and a report checklist
- [x] Baseline setup: the same model, Claude Code with Bash and subagents, no plugin. Universe setup: plugin plus the daemon
- [x] Metrics capture: main-context tokens at the end, total tokens, wall time, model turns, success. Use `claude -p --output-format stream-json` and a parser script `bench/collect.py`
- [x] Ran Oct 10, 2026: 18 runs, all passed. See `bench/RESULTS.md`.
- [x] Run each task 3 times per setup. Then vary the number of streams that need decisions per tick: 1, 3, 6, 10
- [x] Results table plus the go/no-go decision in `bench/RESULTS.md`

**Done when:** the table is filled in and the decision is written down.

### M5: agent workers (done Oct 10, 2026)

An agent is a service whose process is a headless Claude session with a
purpose. It builds on services and `call`, the parts the M4 no-go clause
keeps, not on tick batching.

**Design**
- Create: `serve` with an `agent` block (`purpose`, `model`, `tools`, `pool`)
  instead of `lang`/`code`. The worker runs `priv/sdk/agent_bridge.py`, which
  holds one `claude -p --input-format stream-json --output-format stream-json`
  session and serves one function, `task`.
- Task: `call` with `prompt` (sugar for `fn: "task"`). The session's final
  message is the result (inline or a handle). Calls to one agent run one at a
  time, so it is one conversation that remembers earlier tasks.
- Available: the agent's digest line and the manifest show `idle`/`busy`,
  tasks done and context size.
- Pools: agents sharing `pool`; a call naming the pool goes to a free member
  (lowest ID), or waits until one is free.
- Questions: a reply starting `QUESTION:` becomes `U.ask`; the model answers
  with `reply`.
- Crashes: a dead session is replaced on the next task (context lost); 4
  deaths in 60 s stop the agent. Idle agents stop after `ttl_idle_s`.
- Isolation: `claude` needs your login under `$HOME` and the Claude API, so
  agents are not Seatbelt-wrapped. They run `--restricted`
  (no code-running tools, file tools confined to the project, user/project
  settings ignored), `--strict-mcp-config`, `--permission-mode dontAsk`, with
  `Edit` allow rules only for leased paths and `Read`/`Edit` deny rules for
  `.universe/`. Rules need absolute `//path` form (verified: relative `/path`
  rules matched nothing when passed via `--settings`).

**Evidence**
- Probe: one session stayed alive idle, took a second task with context
  kept; first-call context ~3.0k tokens with a short purpose and Read/Grep,
  against ~26k for default Claude Code (M4).
- Unit/integration: `test/universe/agents_test.exs` against a fake `claude`
  (`test/support/bin/fake_claude`): validation, one session across tasks,
  argv/permission rules, ask/reply, pool split, crash recovery.
- Real run (haiku, release daemon over MCP): a 2-agent pool split 4 tasks
  2/2 in 7.6 s including startup; a read of `.universe/token` was refused; a
  follow-up to one agent recalled exactly the files it had summarised.
- Orchestrated run: headless Claude Code with the plugin, asked to use a
  pool of 3, found the existing pool in the manifest, added one agent, sent 20
  tasks in one tick and wrote a correct 20-line `index.md` in 9 turns / 47 s.

**Follow-ups (done Oct 10, 2026)**
- Sessions persist: each agent gets a `--session-id`, saved in
  `.universe/agents/<name>.json` with a key of its config. Serving it again
  resumes (`--resume`); a crash resumes in a new process; a session that
  can't be resumed falls back to a new one. `"resume": false` opts out.
  Verified with haiku across a full daemon restart.
- Timeouts: the connection passes what is left of the caller's timeout to
  the service (`timeout_ms` on `invoke`, `U.time_left()` in Python); the
  bridge sends a stream-json `interrupt` control request at the deadline, so
  the agent is free again. Invocations whose caller already gave up while
  queued are dropped. Verified with haiku: a 5 s task stopped at ~4 s, the
  next task ran at once.

**M6 benchmark (Oct 11, 2026): NO-GO under the pre-registered rule.**
Agent pools vs Claude Code subagents, 2 tasks × 3 runs, all 12 passed. qa:
agents 42 % of tokens, 59 % of time (win). modules: 213 % of tokens, 130 % of
time (no win), driven by orchestrator turns (13 vs 7). Confound: subagents
ran Opus, agents haiku/sonnet. Agent workers stay an option; subagents stay
the default. Details in `bench/README.md` and `bench/RESULTS-M6.md`.

---

## 3b. Carry-forward notes (from the M1 review)

- [x] **Memory growth:** `Universe.Tick` keeps every worker ever created, including `directive.code` and the `then` steps. M3 GC: drop the code on settle, and prune settled workers past a cap (the event log and run dirs keep the history).
- [x] **Escape matrix (M3):** add "a snippet that calls `setsid` outlives its kill" as a known-failing case so it is measured, not forgotten. Also narrow `(allow mach-lookup)`.
- [~] `c_src/universe_run.c` is built with `-Werror` and has only been tested on macOS. Build and test it on Linux before the Linux adapter. (Oct 11: portable harness `c_src/test/launcher_test.py` — exit codes, signals, framing, group kill on K and on EOF, grace, RLIMIT_FSIZE — passes 12/12 on macOS. The Linux run was skipped: no Linux VM yet.)
- [x] Unknown `wait.ids` now come back as `rejected` lines (they used to shrink the watch silently and return at once).
- [x] The redaction test flushes the log (`EventLog.sync/0`) before checking the file.

## 3c. Linux adapter (Oct 11, 2026: written, not yet run on Linux)

- `Universe.Isolation.Bubblewrap`, picked by default on Linux: `--unshare-all`
  (own network namespace unless a service declares hosts, then
  `--share-net`), `/` read-only, `$HOME` hidden by a tmpfs, project and SDK
  re-exposed read-only, leases bound writable, then `.universe/` hidden
  again (so a lease on `.` can't write it), the run dir and SDK socket bound
  last. `--die-with-parent` plus the PID namespace should also close the
  macOS `setsid` gap. Leases that don't exist yet are created first.
- Coarser than macOS: a service with network gets all hosts, not just its
  ports.
- Verified so far: the argv layering (`test/isolation/bubblewrap_test.exs`).
- [~] Run on Linux (deferred, see section 4): `c_src/test/launcher_test.py` (with gcc and clang) and
  the escape matrix `c_src/test/linux_escape.sh` (args files are generated
  from the adapter), then the full suite.

## 4. Blocked or deferred

- **Deferred (Oct 11, 2026): Linux testing.** Nothing Linux-side has run yet;
  pick it up when a Linux machine or VM is available. Steps:
  1. `cc -O2 -Wall -Wextra -Werror -std=c99 -D_DEFAULT_SOURCE -o /tmp/universe_run c_src/universe_run.c`
     with gcc and clang, then `python3 c_src/test/launcher_test.py /tmp/universe_run` (12 checks).
  2. Install bubblewrap, then `sh c_src/test/linux_escape.sh /tmp/universe_run c_src/test/bwrap_args.txt c_src/test/bwrap_args_net.txt`
     as a normal user (escape matrix, SDK socket, setsid kill, process groups for memory budgets).
  3. Install Elixir 1.20 / OTP 29 and run `mix test` with the Bubblewrap adapter.
  On macOS, Apple's `container` CLI works once its default kernel is installed
  (`container system start --enable-kernel-install`; a large download from GitHub).
- **Blocked:** Kiro integration (MCP registration, steering file, blocking its shell tool). Kiro CLI is not installed. Pick it up after M3 once it is installed and its syntax is checked.
- **Deferred (not v1):** brain mode, Context-Folding and AgentFold, web chat, 3D view, several clients on one Universe, the Linux `box` adapter (unless srt covers it), SQLite event index, the bash `u` helper.

## 5. Open questions

- [ ] What is `box` exactly? It is probably prologic/box (Linux only). Is it needed at all if `srt` covers both operating systems?
- [ ] Are handles readable by every worker, or only by the ID that created them plus explicit grants?
- [x] At the service cap: refuse the new service or reap the oldest idle one? **Decided:** refuse, with "at most 20 live services; kill one first".
- [x] Should `U.ask` also block the worker until the model answers? If so, how does the answer come back: a new `reply` op, or `call` on the asking ID? The v1 ops leave this out, and `asking` needs an answer path. **Decided:** `U.ask` blocks; the model answers with a `reply` op.
- [ ] When a watched run has a `then` chain, does `tick` wake when the parent exits or when the whole chain finishes? The chain's children have no IDs when the watch is set. Proposal: by default the watch covers the chain, and the digest shows each step
- [ ] Where does the event log rotate (size or time), and does `/replay` read rotated files?
