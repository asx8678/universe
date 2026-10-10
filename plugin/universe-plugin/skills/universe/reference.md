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
| serve | `label`, `name` (defaults to label), `lang`, `code`, `budget` (no wall clock by default), `leases`, `network` ["host:port"], `ttl_idle_s` (900), `after`, `quiet` |
| call | `label`, `service`, `fn`, `args` (object → keyword args, list → positional), `timeout_s` (60, max 300), `after`, `quiet` |
| kill | `target` (#id or label), optional `label` |
| reply | `target`, `text`, optional `label` |

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
```

Errors raise `U.UniverseError`. Service functions should return handles for
large results: `return U.put("rows", rows)`. Secrets for a service live in
`.universe/secrets/<service>.env` and reach only that service.

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
