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

**Pilot 3, Oct 11, 2026 (sonnet, after the fixes).** No helpers at all: it
paged all 600 tickets through `run` output in ~50 chunks and judged them in
its own context. Categories 600/600, priorities 598/600 (2 indirect
chargebacks missed: FAIL), 66 turns, 6.9 M orchestrator tokens, 280 s. With
the same model, pilot 2 delegated and pilot 3 didn't: the choice is not
stable at this size for sonnet.

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

## M7 result (Oct 11, 2026): NOT ACCEPTED

Three Opus 5.5 runs, `bench/out7/`, scored with `accept.py`:

| run | grade | built | wired (agent U.calls) | turns | orchestrator tokens | helper tokens | cost (orch.) | steer |
|---|---|---|---|---|---|---|---|---|
| 1 | PASS | yes (db → db2 → db3) | 490 | 42 | 2.63 M | 1.45 M | $4.07 | n/a: no task in flight |
| 2 | PASS | yes (tix, tix2) | 44 | 35 | 1.79 M | 1.11 M | $3.16 | none (window) |
| 3 | PASS | no: agents read exported files | 0 | 41 | 2.02 M | 1.11 M | $3.43 | none (window) |

0 of 3 runs pass (every run is over 25 turns), and no run with a steer
window steered: **not accepted**. Built 2/3, wired 2/3, correct 3/3. Helpers
paid off against pilot 3's no-helper path at this size (66 turns, 6.9 M
tokens, FAIL), with the confound that pilot 3 was sonnet.

Where the turns went (35–42 against M6's 7–13):

- **inspect after nearly every run** (9–13 per run, ~25 %): the digest showed
  one line per run.
- **Agents couldn't read large service results**: over 8,000 characters
  they got a handle and a preview cutting bodies at ~30 characters. In run 1
  four agents stopped to ask, and the service was rebuilt twice (db → db2 →
  db3) with its pools; run 3 avoided services for that reason.
- **Pool calls routed to an agent being killed** in the same tick (run 1:
  40 "no live service a1" failures).
- **`leases` inside the agent block** got "unknown field leases"; run 3
  then grepped the plugin's reference to learn the syntax.
- Verification passes the model chose itself (second-opinion pools, diffs).

Steering: in run 2 the rule arrived while tasks ran; the orchestrator killed
them and re-dispatched, which is right for this task: the rule changes
output already produced, so steering the remaining work can't fix done
work. This task shape cannot tell whether the model steers when it should.

Side effect: run 2's orchestrator wrote Claude Code auto-memory under
`~/.claude/projects/-private-tmp-universe-bench-triage-accept-2/`. Work
dirs are reused by path across rounds, so a later round could read it.

Fixed in 4260748 (with tests): agents page through a handle's whole value
with `handle_read`; pool routing and direct calls skip agents being killed;
"leases go on the serve, next to agent, not inside it"; a finished run's
stdout of ≤ 20 lines / 1,500 chars shows whole in the digest (≤ 3,000
chars a tick). Earlier, from the pilots (e7d5937): tasks for a busy agent
wait in the Tick (timeout starts with the task), `memory: "task"`.

**Reference arm (plain Claude Code, Opus 5.5, its own `Agent` tool, no
plugin; unscored):** 3/3 PASS. Runs 1 and 2 read every ticket in their own
context (39 and 43 turns, 3.5 M and 3.6 M tokens, ~$6.80 each, 427 s and
468 s); run 3 used 13 subagents (48 turns, 7.1 M tokens with 5.3 M in
subagents, $10.43, 1,411 s). The accept runs' orchestrators cost $3.16–4.07
(helper agents are separate processes, not in that figure; their tokens are
in the table) with similar turn counts (35–42). `total_cost_usd` in
stream-json results is cumulative per session: take the last one, don't sum.

# M7.1 acceptance (pre-registered Oct 11, 2026, before any run)

Same task, fixture, prompt, mid-run message, setups and criteria as M7,
on 4260748, with two changes, both decided before any run:

- **Steer is reported, not gated** (see M7: this task can't discriminate
  it). A steer acceptance needs a long single-task shape whose direction
  changes (a review or investigation); that is future work.
- **A fresh work path per round** (`UNIVERSE_BENCH_WORK=/tmp/universe-bench-m71`)
  so no run reads an earlier round's auto-memory.

The 25-turn gate stays. **Accepted** if at least 2 of 3 runs are built,
wired, correct and within 25 turns. M7.1 is the last round before the
benchmark; whatever it shows is recorded as is.

```
UNIVERSE_BENCH_OUT=bench/out71 UNIVERSE_BENCH_WORK=/tmp/universe-bench-m71 \
  python3 bench/run.py --tasks triage --setups accept --runs 3 --budget 25 --go
python3 bench/accept.py bench/out71/triage.accept.*.jsonl
```

## M7.1 result (Oct 11, 2026): NOT ACCEPTED

Three Opus 5.5 runs on 4260748, `bench/out71/`:

| run | grade | built | wired (agent U.calls) | turns | orchestrator tokens | helper tokens | cost (orch.) | wall s |
|---|---|---|---|---|---|---|---|---|
| 1 | PASS | no: agents read exported files | 0 | 28 | 1.11 M | 0.31 M | $2.37 | 320 |
| 2 | PASS | yes (db) | 18 | 35 | 1.49 M | 2.04 M | $2.18 | 365 |
| 3 | PASS | yes (tix) | 120 | 32 | 1.58 M | 3.82 M | $2.87 | 471 |

0 of 3 within 25 turns: not accepted, as pre-registered. Correct 3/3,
built 2/3, wired 2/3 (as in M7); no steers (reported, not gated).

Against M7 the fixes did what they were for: turns 42/35/41 → 28/35/32,
orchestrator cost $3.16–4.07 → $2.18–2.87, wall 437–589 s → 320–471 s,
kills 19–35 → 7–19, `inspect #id` 9–10 → 5–11 (the remaining ones grep or
page outputs over 20 lines). No agent asked how to read a result, and no
call went to a dying agent. The orchestrators still spend turns on their
own verification passes (second-opinion pools, diffs, spot checks) and on
separate kill ticks, and one run delegated without wiring a service.

Against plain Claude Code (reference arm above, 39–48 turns, $6.75–10.43
orchestrator): fewer turns and a third of the orchestrator cost, plus
0.3–3.8 M helper tokens (sonnet, some opus) outside that figure.

Per the pre-registration this was the last round; next is the benchmark,
on a task where agents must look things up while they judge (so wiring is
needed), with helper cost counted in dollars.

# Steer acceptance (pre-registered Oct 11, 2026, before any Opus run)

Does the orchestrator steer a helper whose brief changes mid-task, when
steering is the right response?

**Task (`review`, fixture `fixtures/review/`, made by `gen_review.py`):**
review 100 Python files (80 under `shop/`, 20 under `web/`, ~5,500 lines)
in a stated order for three logic bugs that need reading (inverted
condition, wrong variable, off-by-one; grep can't find them, so a reviewer
takes minutes), and write `review.md`. The prompt delegates explicitly:
one helper agent, one task, all files in order. 10 s after that task
starts, the harness sends: skip `web/` from now on, and also flag functions
whose docstring promises something the code doesn't do (kind `docstring`);
files already reviewed need no second pass. Docstring defects (53 outside
`web/`) sit only in the second half of the order, so only a reviewer
told mid-task finds them; `web/` files all come after the change.

**Grader (`graders/review.py`):** ≥ 80 % of the docstring defects outside
`web/` found, ≤ 2 findings in `web/`.

**A run passes** if a `steer` was delivered, the delegated task was not
killed, and the grader passes. **Accepted** if 2 of 3 Opus runs pass.
Turns reported.

**Pilots (sonnet):** 1 and 2 finished the review before the change could
arrive (~50 s: line-level kinds the reviewer found with grep); the brief
was changed to logic bugs that need reading. Pilot 3: 2 m 46 s review,
steer delivered 90 s in (when its tick returned), grader PASS (44/53
docstring defects, 0 in `web/`), 19 turns. The model sees a user message
only when its tool call returns, so it learns of a change up to `wait`
(≤ 90 s) late; a reviewer's lease on `review.md` blocked the orchestrator's
final write until it killed the reviewer.

```
UNIVERSE_BENCH_OUT=bench/outsteer UNIVERSE_BENCH_WORK=/tmp/universe-bench-steer-opus \
  python3 bench/run.py --tasks review --setups steer --runs 3 --budget 25 --go
python3 bench/accept.py bench/outsteer/review.steer.*.jsonl
```

## Steer acceptance result (Oct 11, 2026): NOT ACCEPTED (1 of 3), steering itself 3 of 3

Three Opus 5.5 runs, `bench/outsteer/`:

| run | steer delivered | task killed | docstring defects | web/ findings | grade | turns | orch. cost | wall s |
|---|---|---|---|---|---|---|---|---|
| 1 | yes | no | 45/53 (85 %) | 0 | PASS | 23 | $1.25 | 443 |
| 2 | yes | no | 41/53 (77 %) | 5 | FAIL | 14 | $1.04 | 364 |
| 3 | yes | no | 9/53 (17 %) | 19 | FAIL | 17 | $0.61 | 187 |

The model did what the test is about in every run: it steered the running
review with the change and never killed or restarted it. Two runs failed on
the grader because the steer landed late: in each run it reached the
reviewer 95 s after its task started, when the orchestrator's 90 s tick came
back (the model reads a user message only between tool calls). Run 3's
reviewer was fast and had passed most files by then (finished 35 s after the
steer). **Finding for Universe:** a model told something mid-tick can't act
until its `wait` returns; a shorter wait while helpers run (or waking the
model on a user message) would cut that delay. Not changed here; recorded.

# Benchmark (M8) fixture: refund claims (built Oct 11, 2026; gates FAIL, not run)

`gen_claims.py` + `write_claims.py`: 300 refund claims written by sonnet from
seeded specs (180 approve, 89 deny, 31 escalate), over 2,000 customers and
5,722 orders with shipments, payments and refunds; `policy.md` says which
records decide each claim type. Grader `graders/claims.py` (≥ 95 % right).

Gates (`audit_claims.py`):

- clear: haiku given each claim with that customer's records agrees on 99.7 % — PASS
- blind: haiku with the claim text only gets 60.3 % (records are needed) — PASS
- script: a regex-and-SQL solver sonnet wrote from 50 labelled claims gets
  **88.7 %** (`graders/claims_script_gate_1.py`; gate < 85 %) — **FAIL**

So as built, one script decides most claims without reading them: the claim
type and the order (by number, or product words plus a month) are easy to
pick out, and each rule is a single SQL check. Accuracy by type: defect
50/61, duplicate 55/60, wrong item 59/65, late 66/73, not received 36/41.
The benchmark was not run on this fixture. To make reading necessary: claims
that mention several orders or products (only one is the subject), types
stated indirectly ("it showed up the day after the party", "two lines on my
statement"), and policy exceptions that turn on what the customer says (a
gift sent to another address, a defect caused by the customer).

## Steer acceptance, round 2 (Oct 11, 2026): ACCEPTED (2 of 3)

Fix between rounds: while an agent task runs, a tick waits at most 20 s
and says "back early: helpers still working" (the skill says: steer now if
the plan changed, else tick again). Same task, criteria and model,
`bench/outsteer2/`:

| run | steer reached the task after | grade | turns | orch. cost | wall s |
|---|---|---|---|---|---|
| 1 | 23 s (was 95 s) | PASS | 11 | $0.29 | 111 |
| 2 | 22 s | FAIL (64 % docstring, 9 in web/) | 12 | $0.25 | 126 |
| 3 | ~20 s | PASS | 12 | $0.28 | 159 |

Run 2: the orchestrator gave the review the default 60 s call timeout, so
the reviewer stopped mid-way; the "continue" task it sent next didn't carry
the change, and the later web/ files got reviewed. Turns fell from 14–23 to
11–12, orchestrator cost from $0.61–1.25 to $0.25–0.29.
