# Universe benchmark (M4)

Does Universe beat plain Claude Code on wide tasks? The thresholds below are
fixed **before** any run, per the plan.

## Setups

Same model, same task prompt, three runs each.

- **baseline** — Claude Code with Bash and its built-in subagents, no plugin,
  in a copy of the fixture.
- **universe** — the `universe` plugin loaded and a daemon running for the
  fixture (`universectl init` + `up`). Bash is redirected to `tick`.

## Tasks

1. **Summarise 20 modules into one index.** Parallel snippets, handles, digest
   compression. (`fixtures/summarize/`)
2. **Make 20 independent edits across files, then run the tests.** Leases,
   `then` chains, failed-first triage. (`fixtures/edits/`)
3. **Run 20 database checks and compile a report.** A persistent service,
   `U.call`, data kept out of the context. (`fixtures/dbchecks/`)

## Metrics (per run, via `collect.py` over `--output-format stream-json`)

- `main_context_tokens` — input tokens of the final assistant turn (what the
  model still carries at the end)
- `total_tokens` — summed input+output across the run
- `wall_s`
- `turns` — model turns (`num_turns`)
- `success` — tests pass, or the report checklist is complete (task-specific
  grader in each fixture's `grade.py`)

## Validity note

Both M2/M3 acceptance runs lost ~10 turns to SQLite failing to open a
read-only DB inside the sandbox. The baseline runs unsandboxed with Bash, so
task 3 (dbchecks) is biased against Universe unless the prompt hints at
`immutable=1`/`uri=True` or a lease on `data/`. Fix the hint (same for both
setups) before the first run.

## Go / no-go (fixed Oct 10, 2026, before the first run)

- **Go:** on at least 2 of the 3 tasks, Universe uses **≥ 50 % fewer
  main-context tokens** at the end **and** is faster or cheaper (lower
  `total_tokens` or lower `wall_s`), with **equal success** (both setups pass).
- **No-go:** otherwise. Keep what won — most likely persistent services and the
  SDK — as a plain MCP server, and drop `tick` batching.

Record the filled table in `RESULTS.md`.

## Running (not run yet — it spends many Claude sessions on the user's plan)

```
python3 bench/run.py --task summarize --setup baseline --runs 3
python3 bench/run.py --task summarize --setup universe --runs 3
# … per task and setup, then:
python3 bench/collect.py bench/out/*.jsonl > bench/RESULTS.md
```

`run.py` is intentionally a thin wrapper that prints the exact `claude -p`
command for each cell; launching dozens of sessions is left to an explicit
decision.
