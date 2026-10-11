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

# M6: agent pools vs Claude Code subagents

Is delegating to Universe agent workers (M5) better than Claude Code's own
subagents (the Agent tool)? Rule fixed **before** any run, Oct 10, 2026.

## Setups

Same orchestrator model, same task prompt (which asks for delegation to
parallel helper agents), three runs each, fresh fixture copy per run.

- **subagents** — Claude Code with its built-in tools including `Agent`,
  no plugin, no Universe.
- **agents** — the plugin plus a daemon; `Agent`/`Task` are not offered, so
  delegation goes through Universe agent workers (`serve` with `agent`).

## Tasks (fixture `fixtures/modules/`: a frozen copy of Universe's own
`lib/universe`, 24 files, ~150 KB)

1. **modules** — `index.md` with one line per file: path, purpose, main
   functions. Grader: every file appears with one of its `def` names.
2. **qa** — answer the 10 questions in `questions.md` (one integer each)
   into `answers.md`. Grader: all 10 right.

## Metrics

As M4, plus helper tokens: subagent calls are in the transcript; agent
workers log each task's tokens to `.universe/agents/*.usage.jsonl`, which
`run.py` copies to `out/<cell>.helpers.json`. `total` = orchestrator +
helpers.

## Go / no-go

- Agents **win a task** if every run passes in both setups, median `total`
  tokens is **≤ 80 %** of subagents', median wall time is **≤ 120 %**, and
  median end-of-run main context is **≤ 110 %**.
- **Go** (recommend agent pools as the way to delegate) if agents win
  **both** tasks. **No-go** otherwise: keep agent workers as an option and
  document subagents as the default.

```
python3 bench/run.py --tasks modules,qa --setups subagents,agents --runs 3 --go
python3 bench/collect.py bench/out6/*.jsonl > bench/RESULTS-M6.md
```

## M6 result

Ran Oct 11, 2026: **NO-GO** (agents won 1 of 2 tasks; go needed both). See
`RESULTS-M6.md`.

- **qa:** agents used 42 % of the subagents' total tokens and 59 % of the
  wall time, same main context, all runs passed → win.
- **modules:** agents used 213 % of the tokens and 130 % of the time → no
  win. The orchestrator itself cost more: 13 turns vs 7 (skill load,
  `inspect` round-trips, spawning agents in one tick and tasking them in the
  next), and each turn re-sends ~35 k of context.
- **Confound, recorded after the runs:** Claude Code's subagents ran on the
  orchestrator's model (Opus 5.5) in every run; the orchestrator gave Universe
  agents haiku or sonnet. The rule counts tokens, not price, so per-token cost
  favours agents further than the table shows; the qa win is partly Opus
  subagents doing more calls (1.0 M helper tokens vs 0.2 M).
- `qa.*.1` was the smoke run, kept as run 1 (same setup). Wall time comes
  from `.wall` files (real elapsed time), after the duration bug fix.

Per the rule: keep agent workers as an option; subagents stay the default
way to delegate. The cheapest lever on the losing task is orchestrator
turns, not helper tokens.

# M7 acceptance: does the orchestrator build, wire and steer helpers?

Fixed Oct 11, 2026, **before** any run. Not a benchmark: one setup is scored,
a reference arm is only reported.

## Task (`triage`, fixture `fixtures/triage/`, made by `gen_triage.py`)

Triage 600 open support tickets in a SQLite database of 3,000 customers,
~13.5 k orders and ~7 k tickets, and write `triage.md`
(`id. category | priority | next action`). The prompt says nothing about
helpers, agents or services.

- **Category** is judgment over free text. Each open ticket was written once
  by sonnet (`write_tickets.py`) from a seeded spec: one real problem, other
  categories' vocabulary in passing (resolved past problems, asides), ten
  personas, 500-1,200 chars, ~10 % stating the problem only at the end.
- **Priority** needs per-customer lookups (other unresolved tickets, 90-day
  spend, refunds, sign-up date).
- **Volume** is what makes helpers the right call: ~600 × ~850 chars is
  ~130 k tokens of text, too much to page into the orchestrator's own context
  sensibly (at 240 it was ~55 k, which an orchestrator can just read).

Gates the fixture passed before any run (`audit_triage.py`, Oct 11, 2026):

- clarity: haiku, reading each ticket with the definitions and the
  chargeback rule, agrees with all 600 labels (gate ≥ 99 %);
- regex: sonnet, given 50 labelled open tickets, wrote a keyword/regex
  classifier with aside and negation filtering
  (`graders/triage_regex_gate_{1,2}.py`): 93.0 % and 85.2 % of categories on
  two samples (gate ≤ 93 %), 17 and 13 chargeback errors on 52 positives
  (gate ≥ 5), so a regex-only route fails the 100 % priority bar;
- history: naive Bayes trained on the 6,000 closed tickets with categories
  (which the model can read) gets 60.3 % (gate ≤ 93 %).

The first regex sample cleared the original 90 % category bar, so the bar
was raised to 95 % before any run: haiku reading the tickets gets 100 %,
leaving room for agents working through long slices; a regex has to beat
what one tuned on labelled open tickets managed.

**Pilot, Oct 11, 2026 (why the task changed).** The first fixture (240
tickets from template sentences) was solved by a sonnet orchestrator in
48 s and 11 turns with no helpers: it read one dump of all tickets, spotted
the templates and wrote an exact-phrase regex (240/240), then applied the
chargeback rule with a `chargeback|disput` regex (26/26). Under the skill's
"don't build for one-off work" that was the right call, so the task, not the
teaching, was changed.

Mid-run, the harness sends a second user message (stream-json stdin): any
ticket that mentions a chargeback (filed or threatened, by name or as asking
the bank or card issuer to reverse the payment) is `urgent`, for every
ticket including ones already triaged. About half of those tickets never
use the words "chargeback" or "dispute", so re-checking done tickets takes
reading, not a regex. It goes 8 s after the first agent task starts (the
model reads it when its current tick returns, while tasks still run), else
at 4 min, else right after the first answer. Whether an agent task was in
flight when it went in is recorded per run.

Grader (`graders/triage.py`, answers outside the fixture): every open ticket
exactly once, every priority right (chargeback rule included), ≥ 95 % of
categories right.

**Pilot 2, Oct 11, 2026 (sonnet orchestrator, this fixture).** Grader PASS
(600/600, 600/600), 228 s, 17 turns, orchestrator 0.70 M tokens, helpers
3.9 M. It exported the tickets to 20 files, served one sonnet agent (`Read`
only, `"pool"` set) and sent it 20 tasks in one tick; it computed priority
itself in SQL, so agents had nothing to look up (no code service: built and
wired both no, by task design: every priority rule is plain SQL). Two
Universe defects, fixed before pilot 3:

- An agent runs one task at a time, but a direct call to a busy agent was
  started at once and queued on its connection, so the 60 s call timeout
  counted queue time: 13 of 20 tasks failed. Now the Tick holds such a task
  in `queued` ("waits behind N tasks on cls"), and its timeout starts when
  it does.
- One session kept all 22 tasks: 188.9 k tokens of context re-read on every
  model call. New agent option `"memory": "task"` (a fresh session per
  task); the default stays `"session"`, and an agent's idle line now says
  so past 100 k tokens.

The mid-run rule arrived with tasks in flight (window: yes); it was not
steered (agents owned categories, not priorities): the orchestrator found
the chargebacks itself and got all 52 right.

**Stopping rule:** after these fixes and one more sonnet pilot, the Opus runs
go ahead whatever pilot 3 shows, unless the harness itself breaks.
Otherwise the acceptance turns into development.

## Setups

- **accept** (scored): plugin + daemon, `Agent`/`Task` disallowed, Opus 5.5
  orchestrator (claude's default), helper model left to the orchestrator.
  3 runs; 5 if they split 2–1 or 1–2. `--max-budget-usd 25` per run, 30 min.
- **plain** (reference, unscored, after the accept runs): Claude Code with
  its own tools including `Agent`, no plugin, same prompt and mid-run
  message, 3 runs.
- `Skill` is allowed, so the plugin's skill can load. It was not in the
  M4-M6 allow-lists: those runs tried to load it and were denied (one
  `permission_denied` each), so they ran on the tick description and
  SessionStart hook alone.
- Pilot first: one accept run with a sonnet orchestrator to check the
  harness; not counted.

## Criteria (`accept.py`, from the event log and transcript)

- **Built:** an agent served with `services` naming a code service that
  served in the run.
- **Wired:** at least one `call` with `via: sdk` under an agent's ID.
- **Steered:** at least one delivered `steer` event (attempts and rejection
  reasons reported too). If no agent task was in flight when the mid-run
  message went in, steering is n/a for that run, not a fail.
- **Correct:** the grader passes.
- **Turns:** reported, not gated; M6 took 7–13. Over 15 is flagged, over 25
  counts as a failure of the run.
- **Helper tokens:** reported and flagged, not gated. `--max-budget-usd`
  caps only the orchestrator; agents are separate `claude` processes with
  no budget flag, bounded by the 30-min kill. Agent sessions grow across
  tickets and tasks, which is a finding to measure.
- Also reported: serve and task in one tick, run output `Read` into the
  main context, helper model, end-of-run main context.

A run **passes** if it is built, wired, correct and within 25 turns.
**Accepted** if at least 2 of 3 runs pass and at least one run with a steer
window steered. A run that solves the task without helpers is reported as
its own finding (compare its cost with the plain arm), not as a pass.

```
python3 bench/gen_triage.py && python3 bench/write_tickets.py && python3 bench/audit_triage.py
python3 bench/gen_triage.py
UNIVERSE_BENCH_OUT=bench/out7 python3 bench/run.py --tasks triage --setups accept --runs 3 --budget 25 --go
UNIVERSE_BENCH_OUT=bench/out7 python3 bench/run.py --tasks triage --setups plain --runs 3 --budget 25 --go
python3 bench/accept.py bench/out7/triage.*.jsonl
```
