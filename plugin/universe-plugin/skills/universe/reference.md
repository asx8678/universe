# Universe reference

## tick

```json
{
  "directives": [ { "op": "run", "label": "...", "...": "..." } ],
  "wait": { "until": "all", "ids": ["#5", "dedupe"], "timeout_s": 60 },
  "since": 812
}
```

- `wait.until`: `all` (default) or `any` of the watched IDs settled. Watched IDs
  default to the ones this tick created (then steps join automatically); with
  none, every live ID. `serving` and `asking` count as settled.
- Universe also wakes you early when a failed or asking worker has waited 20 s
  unreported, and at `timeout_s` (default 60, max 90).
- `since` replays everything after an event cursor; normally omit it.

### Directive fields

| op | fields |
|---|---|
| run | `label`, `lang` (python, bash, elixir), `code`, `budget` {`wall_s` 120, `out_kb` 256, `mem_mb` 2048}, `leases` [paths], `after` [labels, #ids], `then` [run directives], `quiet` |
| serve | `label`, `name` (defaults to label), `lang`, `code`, `budget` (no wall clock by default), `leases`, `network` ["host:port"], `ttl_idle_s` (900), `after`, `quiet`; or `agent` instead of `lang`/`code` (fields below) |
| call | `label`, `service`, `fn`, `args` (object → keyword args, list → positional), `timeout_s` (60, max 300), `after`, `quiet` |
| kill | `target` (#id or label), optional `label` |
| reply | `target`, `text`, optional `label` |
| steer | `target` (a busy agent, or its task), `text`, `interrupt` (false), optional `label` |

Labels: 1-40 chars of letters, digits, `_ . -`, unique within a batch. A label
from an earlier tick refers to the newest worker that used it.

### Digest

```
t12 · 4 changed · 1 running · cursor 812
#7   failed   router-patch exit 1 · test/router_test.exs:42 assertion failed
#9   asking   ui-build     asks: Use the new tokens file or the old one?
#5   done     pg-extract   41s · → h:5/orders (1,240 rows × 3 cols)
#8   running  dedupe       2m10s · last: scanning 800/1240
#4   serving  pg           serving pg · fns: query, tables · Postgres reader
+2 auto-acked (lint, format) · inspect("t12") for all events
```

Statuses: queued, running, serving, asking, done, failed, budget (a budget
killed it), killed, rejected (never ran; the line gives the reason).

## inspect

`{"target": "manifest" | "#5" | "h:5/orders" | "t12", "offset": 0, "limit": 200, "grep": ""}`.
Output is paged by lines (a tail by default); `grep` is a regex.

## SDK (Python shown; Elixir has the same `U` functions)

```python
h = U.put("orders", rows)          # list of dicts → table handle; str → text; else json
rows = U.get("h:5/orders")
U.put_file("report", "/path/in/project/or/run/dir.pdf")
r = U.call("pg", "query", {"sql": "select 1"}, timeout_s=60)
U.progress("scanning 800/1240")
answer = U.ask("Which file?")      # status asking until you send a reply directive
U.serve("pg", {"query": query, "tables": tables}, "Postgres reader for orders DB")
U.inbox()                          # in a service function: steers for this call
```

Errors raise `U.UniverseError`. Service functions should return handles for
large results: `return U.put("rows", rows)`. Secrets for a service live in
`.universe/secrets/<service>.env` and reach only that service. `U.serve` sends
each function's parameters and the first paragraph of its docstring: an agent
given the service sees them as its tool's schema, so name parameters well.

## Worked examples

### 1. Many independent checks in one tick

```json
{"directives": [
  {"op":"run","label":"unit","lang":"bash","code":"mix test test/unit"},
  {"op":"run","label":"lint","lang":"bash","code":"mix credo --strict","quiet":true},
  {"op":"run","label":"todo-count","lang":"python",
   "code":"import pathlib\nprint(sum(p.read_text().count('TODO') for p in pathlib.Path('lib').rglob('*.ex')))"}
], "wait": {"timeout_s": 90}}
```

### 2. A database connector service, then data that never enters the context

```json
{"directives": [
  {"op":"serve","label":"db","lang":"python","code":
   "import sqlite3\ncon = sqlite3.connect('data/shop.db', check_same_thread=False)\ndef query(sql):\n    cur = con.execute(sql)\n    cols = [c[0] for c in cur.description]\n    return U.put('q', [dict(zip(cols, r)) for r in cur.fetchall()])\nU.serve('db', {'query': query}, 'SQLite reader for data/shop.db')"},
  {"op":"call","label":"orders","service":"db","fn":"query","args":{"sql":"select * from orders"}}
]}
```

The digest shows `→ "h:7/q"`; `inspect("h:7/q")` previews it, and later code
reads it with `U.get("h:7/q")`.

### 3. Edits under leases, then the tests

```json
{"directives": [
  {"op":"run","label":"patch-a","lang":"python","leases":["lib/a.ex"],
   "code":"import re,pathlib\np=pathlib.Path('lib/a.ex')\np.write_text(p.read_text().replace('old_name','new_name'))"},
  {"op":"run","label":"patch-b","lang":"python","leases":["lib/b.ex"],"code":"..."},
  {"op":"run","label":"tests","lang":"bash","code":"mix test","after":["patch-a","patch-b"]}
]}
```

Two directives can't lease overlapping paths at once; the second is rejected
and names the holder.

### 4. A pool of agents for many small reviews

```json
{"directives": [
  {"op":"serve","label":"rev-a","agent":{"purpose":"You review one Elixir file for bugs. Answer with at most 3 findings, each file:line and one sentence.","model":"haiku","pool":"reviewers"}},
  {"op":"serve","label":"rev-b","agent":{"purpose":"You review one Elixir file for bugs. Answer with at most 3 findings, each file:line and one sentence.","model":"haiku","pool":"reviewers"}},
  {"op":"call","label":"r-tick","service":"reviewers","prompt":"Review lib/universe/tick.ex"},
  {"op":"call","label":"r-worker","service":"reviewers","prompt":"Review lib/universe/worker.ex"},
  {"op":"call","label":"r-handles","service":"reviewers","prompt":"Review lib/universe/handles.ex"}
], "wait": {"until":"all","timeout_s":90}}
```

Each call goes to whichever agent is free; the rest wait. An agent's answer is
the call's result (a handle if large). Agents stay up between ticks: send a
follow-up to `rev-a` by name and it still knows what it read. They stop after
`ttl_idle_s` (900 s) idle, or on `kill`.

### 5. A service an agent uses as its tool, then a steer

```json
{"directives": [
  {"op":"serve","label":"db","lang":"python","code":
   "import sqlite3\ncon = sqlite3.connect('data/shop.db', check_same_thread=False)\ndef query(sql):\n    \"\"\"Run one read-only SQL query; rows come back as a list of dicts.\"\"\"\n    cur = con.execute(sql)\n    cols = [c[0] for c in cur.description]\n    return [dict(zip(cols, r)) for r in cur.fetchall()]\nU.serve('db', {'query': query}, 'SQLite reader for data/shop.db')"},
  {"op":"serve","label":"analyst","agent":{"purpose":"You answer questions about the shop database. Query it with the db tool; answer in at most 5 lines.","model":"haiku","services":["db"]}},
  {"op":"call","label":"a1","service":"analyst","prompt":"Which 3 products sold most last month?","timeout_s":300}
], "wait": {"ids":["a1"], "timeout_s": 90}}
```

The agent gets `mcp__services__db__query` and queries the database itself;
only its answer reaches you. While `a1` runs you can redirect it:
`{"op":"steer","target":"a1","text":"Count refunds as negative sales."}`.

Agent fields: `purpose` (its system prompt, required), `model` (`haiku`,
`sonnet`, `opus` or a full model name; default: your CLI's default), `tools`
(from `Read Grep Glob Edit Write NotebookEdit WebSearch WebFetch TodoWrite`;
default `Read Grep Glob`; writing tools need `leases`), `services` (code
services it may call as tools, named `<service>__<function>`; each must be
live or served in the same tick, and the agent starts once they serve; no
agents or pools), `pool`, `resume` (default true: serving the same agent
again, after a kill or a daemon restart, resumes its conversation; a changed
purpose, model, tools, leases or services starts a new one). A task past its
call's `timeout_s` (default 60, max 1800) is interrupted and the agent is
free again; if its session crashes, the next task resumes it.

A service result over 8,000 characters reaches the agent as a handle and its
preview (`handle_preview` shows it again); it can pass the handle to another
service function. The kernel lets an agent call only its listed services.

`steer` adds an instruction to a busy agent's current task; the session takes
it in at its next tool step, and the task's answer comes after it. With
`"interrupt": true` the turn stops first and the instruction starts the next
one. A steer to an idle or asking agent is rejected: give it a task, or
`reply`.

Agents run `claude --restricted`: no Bash or other code-running tools, file
tools confined to the project, writes only under their leases, `.universe/`
unreadable. They run outside the code-worker sandbox, since `claude` needs
your login and the Claude API. Each task uses your Claude plan.
