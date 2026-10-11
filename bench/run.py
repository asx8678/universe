#!/usr/bin/env python3
"""Run benchmark cells: fresh fixture copy → (daemon) → claude -p → grade.

    python3 bench/run.py --tasks summarize --setups universe --runs 1        # dry run
    python3 bench/run.py --tasks summarize,edits,dbchecks --setups baseline,universe --runs 3 --go

Without --go nothing is launched. With --go each cell writes
bench/out/<task>.<setup>.<n>.jsonl (the stream-json transcript) and
.<n>.grade (the grader's verdict); collect.py turns them into RESULTS.md.
Cells run sequentially, interleaved by run number so time-of-day effects
spread over both setups.

Both setups use --strict-mcp-config, so neither sees the user's MCP servers;
the universe setup gets only its own daemon through --mcp-config (nothing is
written to ~/.claude.json) plus the plugin via --plugin-dir. Bash is allowed
in both: in the universe setup the plugin's hook is what redirects it.

M7 acceptance (task `triage`, setups `accept` and `plain`): the prompt goes
in on stdin (stream-json) and a second user message, a new rule, follows
mid-run (see MIDRUN and converse()), so steering busy helpers is possible:

    python3 bench/gen_triage.py
    UNIVERSE_BENCH_OUT=bench/out7 python3 bench/run.py --tasks triage --setups accept --runs 3 --go
    python3 bench/accept.py bench/out7/triage.accept.*.jsonl
"""

import argparse
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.request

BENCH = pathlib.Path(__file__).resolve().parent
REPO = BENCH.parent
OUT = pathlib.Path(os.environ.get("UNIVERSE_BENCH_OUT", BENCH / "out"))
WORK = pathlib.Path(os.environ.get("UNIVERSE_BENCH_WORK", "/tmp/universe-bench"))
UCTL = REPO / "_build/prod/rel/universe/bin/universectl"
PLUGIN = REPO / "plugin/universe-plugin"
RUN_TIMEOUT_S = 30 * 60

TASKS = {
    "summarize": "Summarise every module under lib/ into a single index file, index.md, "
    "with one line per module: its path, its purpose, and its functions. The modules are independent.",
    "edits": "In each file under lib/, rename the function old_api to new_api, both the definition "
    "and its call sites. The files are independent. Then run `python3 run_tests.py` and make it pass.",
    "dbchecks": "Answer the 20 checks in checks.md against the SQLite database data/app.db and write "
    "report.md exactly as checks.md describes.",
    # M6: delegation, same wording for both setups.
    "modules": "Summarise every file under lib/ into index.md, one line per file: its path, its purpose "
    "and its main functions. Delegate reading the files to parallel helper agents; you coordinate "
    "and write index.md.",
    "qa": "Answer the questions in questions.md about the code under lib/ and write answers.md as it "
    "describes. Delegate the reading to parallel helper agents; you coordinate and write answers.md.",
}
FIXTURE = {"modules": "modules", "qa": "modules"}

# M7 acceptance: no word about helpers in the prompt.
TASKS["triage"] = "Triage the open tickets in data/support.db as instructions.md describes, and write triage.md."
# Steer acceptance: the delegation is given; the question is what the model
# does when the brief changes while its helper works.
TASKS["review"] = ("Review the code as instructions.md describes and write review.md. Hand the whole review "
                   "to one helper agent as a single task (all files, in REVIEW_ORDER.md order) and coordinate; "
                   "don't review the files yourself.")

# A user message sent while the run is under way: MIDRUN_AFTER_S after the
# first delegated task starts (an agent `call` in the event log, or an
# Agent tool use), else after MIDRUN_FALLBACK_S, else right after the first
# answer. It applies to tickets already triaged, so steer, re-task or redo
# are all real choices.
MIDRUN = {
    "triage": "Change of rule from the support lead: any ticket that mentions a chargeback, or disputing "
    "the charge with a bank or card issuer (already filed or only threatened), is priority `urgent`, "
    "whatever else applies. Apply it to every open ticket, including ones already triaged.",
    # Steer acceptance: the change applies to the work still ahead, and done
    # work stays valid, so steering the running review beats restarting it.
    "review": "Change from the tech lead, effective now: skip everything under web/ from here on (another "
    "team reviews it), and also flag every function whose docstring promises something its code "
    "doesn't do, with kind `docstring`. Files already reviewed don't need another pass.",
}
MIDRUN_AFTER_S = {"triage": 8, "review": 10}
MIDRUN_FALLBACK_S = 240

# Skill: the plugin's skill is part of what the model is taught (M4-M6 runs
# had it denied; see README).
COMMON_TOOLS = ["Bash", "Read", "Edit", "Write", "Glob", "Grep", "Agent", "Task", "Skill"]
UNIVERSE_TOOLS = ["mcp__universe__tick", "mcp__universe__inspect"]


def log(msg):
    line = f"{time.strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    with open(OUT / "progress.log", "a") as f:
        f.write(line + "\n")


def fresh_copy(task, cell):
    work = WORK / cell
    if work.exists():
        shutil.rmtree(work)
    shutil.copytree(BENCH / "fixtures" / FIXTURE.get(task, task), work)
    return work


def start_daemon(work):
    subprocess.run([UCTL, "init", work, "--no-claude"], check=True, capture_output=True)
    port = (work / ".universe/port").read_text().strip()
    token = (work / ".universe/token").read_text().strip()
    logf = open(work.parent / f"{work.name}.daemon.log", "w")
    proc = subprocess.Popen([UCTL, "up", work], stdout=logf, stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(80):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=1)
            break
        except Exception:
            time.sleep(0.25)
    else:
        raise RuntimeError(f"daemon for {work} did not come up")
    cfg = {
        "mcpServers": {
            "universe": {
                "type": "http",
                "url": f"http://127.0.0.1:{port}/mcp",
                "headers": {"Authorization": f"Bearer {token}"},
                "alwaysLoad": True,
                "timeout": 120000,
            }
        }
    }
    cfg_path = work.parent / f"{work.name}.mcp.json"
    cfg_path.write_text(json.dumps(cfg))
    return proc, cfg_path


def stop_daemon(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=15)
    except Exception:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except Exception:
            pass


def command(task, setup, cfg_path, model=None, budget=None):
    prompt = [] if task in MIDRUN else [TASKS[task]]
    args = ["claude", "-p", *prompt, "--output-format", "stream-json", "--verbose", "--strict-mcp-config"]
    if task in MIDRUN:
        args += ["--input-format", "stream-json", "--replay-user-messages"]
    if model:
        args += ["--model", model]
    if budget:
        args += ["--max-budget-usd", str(budget)]
    tools = COMMON_TOOLS
    if setup in ("universe", "agents", "accept", "steer"):
        args += ["--mcp-config", str(cfg_path), "--plugin-dir", str(PLUGIN)]
        tools = COMMON_TOOLS + UNIVERSE_TOOLS
    if setup in ("agents", "accept", "steer"):
        # Delegation must go through Universe agents, not the built-in Agent tool.
        tools = [t for t in tools if t not in ("Agent", "Task")]
        args += ["--disallowedTools", "Agent", "Task"]
    return args + ["--allowedTools", *tools]


def send_user(proc, text):
    msg = {"type": "user", "message": {"role": "user", "content": text}}
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()


def agent_task_started(work):
    """Whether the daemon's event log has a call that hands an agent a task."""
    log_path = work / ".universe/log/events.jsonl"
    if not log_path.exists():
        return False
    for line in log_path.read_text().splitlines():
        if '"type":"call"' in line.replace(" ", "") and '"prompt"' in line:
            return True
    return False


def converse(cmd, work, out, cell, task):
    """Runs claude with the prompt on stdin, sends MIDRUN[task] mid-run and
    closes stdin once an answer follows that message being taken in."""
    proc = subprocess.Popen(cmd, cwd=work, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, bufsize=1)
    started = time.time()
    st = {"sent": False, "echoed": False, "trigger_at": None, "closed": False}
    lock = threading.Lock()

    def send_rule(why):
        with lock:
            if st["sent"] or proc.poll() is not None:
                return
            st["sent"] = True
            send_user(proc, MIDRUN[task])
        (OUT / f"{cell}.midrun").write_text(json.dumps({"after_s": round(time.time() - started, 1), "at": time.time(), "why": why}) + "\n")
        log(f"  {cell}: mid-run message sent at {time.time() - started:.0f}s ({why})")

    def close_stdin():
        with lock:
            if not st["closed"]:
                st["closed"] = True
                proc.stdin.close()

    def watch():
        while proc.poll() is None and not st["sent"]:
            now = time.time()
            if st["trigger_at"] is None and agent_task_started(work):
                st["trigger_at"] = now + MIDRUN_AFTER_S[task]
            if st["trigger_at"] and now >= st["trigger_at"]:
                send_rule(f"{MIDRUN_AFTER_S[task]}s after the first delegated task")
            elif now - started >= MIDRUN_FALLBACK_S:
                send_rule(f"fallback at {MIDRUN_FALLBACK_S}s")
            time.sleep(1)

    killer = threading.Timer(RUN_TIMEOUT_S, lambda: (log(f"timeout {cell} after {RUN_TIMEOUT_S}s"), proc.kill()))
    killer.start()
    threading.Thread(target=watch, daemon=True).start()
    send_user(proc, TASKS[task])
    for line in proc.stdout:
        out.write(line)
        out.flush()
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e.get("type") == "assistant" and st["trigger_at"] is None:
            for c in e.get("message", {}).get("content", []):
                if c.get("type") == "tool_use" and c.get("name") in ("Agent", "Task"):
                    st["trigger_at"] = time.time() + MIDRUN_AFTER_S[task]
        elif e.get("type") == "user" and e.get("isReplay") and MIDRUN[task][:30] in line:
            st["echoed"] = True
        elif e.get("type") == "result":
            if not st["sent"]:
                send_rule("the first answer came before the trigger")
            elif st["echoed"]:
                close_stdin()
            else:
                # Sent but not yet taken in: give it a turn, then stop waiting.
                threading.Timer(300, close_stdin).start()
    proc.wait()
    killer.cancel()


def run_cell(task, setup, n, go, model=None, budget=None):
    cell = f"{task}.{setup}.{n}"
    if not go:
        print(f"# {cell}: copy fixtures/{task} → {WORK / cell}; " + " ".join(command(task, setup, "<cfg>", model, budget)) + " …")
        return
    work = fresh_copy(task, cell)
    proc = cfg = None
    try:
        if setup in ("universe", "agents", "accept", "steer"):
            proc, cfg = start_daemon(work)
        log(f"start {cell}")
        started = time.time()
        with open(OUT / f"{cell}.jsonl", "w") as out:
            if task in MIDRUN:
                converse(command(task, setup, cfg, model, budget), work, out, cell, task)
            else:
                try:
                    subprocess.run(command(task, setup, cfg, model, budget), cwd=work, stdout=out,
                                   stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=RUN_TIMEOUT_S)
                except subprocess.TimeoutExpired:
                    log(f"timeout {cell} after {RUN_TIMEOUT_S}s")
        # Real elapsed time: with background subagents a run emits several
        # result events, and the last one's duration_ms covers only its turn.
        (OUT / f"{cell}.wall").write_text(f"{time.time() - started:.1f}\n")
        helpers = [json.loads(l) for f in sorted((work / ".universe/agents").glob("*.usage.jsonl"))
                   for l in f.read_text().splitlines() if l.strip()]
        events = work / ".universe/log/events.jsonl"
        if events.exists():
            shutil.copy(events, OUT / f"{cell}.events.jsonl")
        if setup in ("agents", "accept", "steer"):
            (OUT / f"{cell}.helpers.json").write_text(json.dumps({
                "tokens": sum(h["tokens"] for h in helpers), "tasks": len(helpers),
                "agents": len(list((work / ".universe/agents").glob("*.usage.jsonl"))),
                "models": sorted({str(h.get("model")) for h in helpers})}))
        grade = subprocess.run([sys.executable, BENCH / "graders" / f"{task}.py"], cwd=work,
                               capture_output=True, text=True)
        verdict = (grade.stdout.strip().splitlines() or ["FAIL: grader printed nothing"])[-1]
        (OUT / f"{cell}.grade").write_text(verdict + "\n")
        log(f"done  {cell} in {time.time() - started:.0f}s · {verdict}")
    finally:
        if proc:
            stop_daemon(proc)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tasks", default="summarize,edits,dbchecks")
    ap.add_argument("--setups", default="baseline,universe")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--start", type=int, default=1, help="first run number")
    ap.add_argument("--go", action="store_true", help="actually launch (spends Claude plan usage)")
    ap.add_argument("--model", help="orchestrator model (default: claude's default)")
    ap.add_argument("--budget", type=float, help="--max-budget-usd per run")
    a = ap.parse_args()

    tasks, setups = a.tasks.split(","), a.setups.split(",")
    for t in tasks:
        assert t in TASKS, t
    OUT.mkdir(exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    if {"universe", "agents", "accept", "steer"} & set(setups) and not UCTL.exists():
        sys.exit(f"build the release first: MIX_ENV=prod mix release ({UCTL} missing)")

    for n in range(a.start, a.start + a.runs):
        for task in tasks:
            for setup in setups:
                run_cell(task, setup, n, a.go, a.model, a.budget)
    if not a.go:
        print("\n(dry run — pass --go to launch; this spends Claude plan usage)", file=sys.stderr)


if __name__ == "__main__":
    main()
