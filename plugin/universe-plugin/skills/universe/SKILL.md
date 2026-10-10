---
name: universe
description: Run all code, tests, builds, DB queries and long-lived helpers through the Universe daemon (mcp__universe__tick, mcp__universe__inspect) instead of Bash. Use for any execution, for parallel work across files, or when a task needs a persistent connector or tool.
allowed-tools: mcp__universe__tick, mcp__universe__inspect
---

# Universe

You are the only brain. Universe is your hands: it runs your code as workers
with IDs (`#1`, `#2`, …) in a sandbox, and answers each `tick` with one compact
digest. Bash is off in this project; read and edit files with your own tools.

## Loop
1. Plan the next batch. Independent jobs become separate directives.
2. Call `mcp__universe__tick` once with all of them and a `wait`.
3. Read the digest. Act on `failed` and `asking` lines first.
4. Call `mcp__universe__inspect` only when a line isn't enough (`#5` for code
   and output, `t12` for every event of a tick, `h:5/rows` for a handle).

## Directives
- `run`: one-shot code. `{"op":"run","label":"tests","lang":"bash","code":"mix test"}`.
  `lang` is `python`, `bash` or `elixir`. Optional: `budget` `{wall_s, out_kb, mem_mb}`,
  `leases` (paths it writes), `after` (labels/IDs that must finish first),
  `then` (runs started when it exits 0, without waking you), `quiet` (fold a
  success into the auto-acked line).
- `serve`: a long-lived service. Its code calls `U.serve(name, {fn: callable}, describe)`.
  Add `network: ["host:port"]` if it must reach a server, `ttl_idle_s` to change
  the 900 s idle stop.
- `call`: `{"op":"call","label":"n","service":"pg","fn":"query","args":{"sql":"..."}}`.
  Small results show inline; large ones become a handle.
- Agents: a `serve` with an `agent` block instead of code is a helper Claude
  session with a purpose. It stays up, shows `idle`/`busy` in the manifest, and
  takes tasks as calls with a `prompt`; it remembers earlier tasks.
  `{"op":"serve","label":"reviewer","agent":{"purpose":"Review Elixir code for bugs","model":"haiku"}}`
  then `{"op":"call","label":"r1","service":"reviewer","prompt":"Review lib/x.ex"}`.
  Agent tools default to `Read, Grep, Glob`; `Edit`/`Write` need `leases`. Agents
  can't run code. Give several agents the same `"pool":"reviewers"` and call
  the pool: each task goes to a free agent. An agent with a question shows as
  `asking`; answer with `reply`.
- `kill`: `{"op":"kill","target":"#5"}`. `reply`: answer a worker that is
  `asking`: `{"op":"reply","target":"#9","text":"..."}`.

## Inside your code (`U` is preloaded in Python and Elixir)
`U.put(name, value)` → `h:<id>/<name>` · `U.get(handle)` · `U.call(service, fn, args)` ·
`U.progress(text)` · `U.ask(question)` (blocks for your reply) · `U.serve(...)`.

## Rules
- Start a session with `inspect("manifest")`: services may already be running.
- Never move large data through directives or digests: store it with `U.put`
  and pass handles like `h:5/orders` to later code.
- The project is read-only to workers except their `leases`; there is no
  network except a service's declared ports. A write outside a lease fails.
- Keep `wait.timeout_s` at 90 or less. An empty `directives` list just waits.
- Bad directives come back as `rejected` lines with the reason; fix and resend.

Full schemas and worked examples: [reference.md](reference.md).
