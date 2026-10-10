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

The M2/M3 acceptance runs lost ~10 turns to SQLite failing to open a
database inside the sandbox. The cause was a Universe bug, not SQLite: the
profile denied `stat` on the project's ancestor directories under `$HOME`,
which path resolution needs. It was fixed (stat-only on exact ancestors)
before the benchmark, so task 3 runs with no hint in either setup.

## Go / no-go (fixed Oct 10, 2026, before the first run)

- **Go:** on at least 2 of the 3 tasks, Universe uses **≥ 50 % fewer
  main-context tokens** at the end **and** is faster or cheaper (lower
  `total_tokens` or lower `wall_s`), with **equal success** (both setups pass).
- **No-go:** otherwise. Keep what won — most likely persistent services and the
  SDK — as a plain MCP server, and drop `tick` batching.

Record the filled table in `RESULTS.md`.

## Running

```
python3 bench/run.py --runs 1                 # dry run: prints each cell
python3 bench/run.py --runs 3 --go            # launches (spends Claude plan usage)
python3 bench/collect.py bench/out/*.jsonl > bench/RESULTS.md
```

Each cell gets a fresh copy of its fixture under `/tmp/universe-bench`
(override with `UNIVERSE_BENCH_WORK`); the universe setup starts its own daemon
from the release build. Graders live in `graders/`, outside the fixtures, so the
model never sees the expected answers.

## Result

Ran Oct 10, 2026: **NO-GO** (0 of 3 tasks won). See `RESULTS.md` and the M4
section of `docs/PLAN.md`.
