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
"""

import argparse
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

BENCH = pathlib.Path(__file__).resolve().parent
REPO = BENCH.parent
OUT = pathlib.Path(os.environ.get("UNIVERSE_BENCH_OUT", BENCH / "out"))
WORK = pathlib.Path(os.environ.get("UNIVERSE_BENCH_WORK", "/tmp/universe-bench"))
UCTL = REPO / "_build/prod/rel/universe/bin/universectl"
PLUGIN = REPO / "plugin/universe-plugin"
RUN_TIMEOUT_S = 20 * 60

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

COMMON_TOOLS = ["Bash", "Read", "Edit", "Write", "Glob", "Grep", "Agent", "Task"]
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


def command(task, setup, cfg_path):
    args = ["claude", "-p", TASKS[task], "--output-format", "stream-json", "--verbose", "--strict-mcp-config"]
    tools = COMMON_TOOLS
    if setup in ("universe", "agents"):
        args += ["--mcp-config", str(cfg_path), "--plugin-dir", str(PLUGIN)]
        tools = COMMON_TOOLS + UNIVERSE_TOOLS
    if setup == "agents":
        # Delegation must go through Universe agents, not the built-in Agent tool.
        tools = [t for t in tools if t not in ("Agent", "Task")]
        args += ["--disallowedTools", "Agent", "Task"]
    return args + ["--allowedTools", *tools]


def run_cell(task, setup, n, go):
    cell = f"{task}.{setup}.{n}"
    if not go:
        print(f"# {cell}: copy fixtures/{task} → {WORK / cell}; " + " ".join(command(task, setup, "<cfg>")[:8]) + " …")
        return
    work = fresh_copy(task, cell)
    proc = cfg = None
    try:
        if setup in ("universe", "agents"):
            proc, cfg = start_daemon(work)
        log(f"start {cell}")
        started = time.time()
        with open(OUT / f"{cell}.jsonl", "w") as out:
            try:
                subprocess.run(command(task, setup, cfg), cwd=work, stdout=out, stderr=subprocess.STDOUT,
                               stdin=subprocess.DEVNULL, timeout=RUN_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                log(f"timeout {cell} after {RUN_TIMEOUT_S}s")
        # Real elapsed time: with background subagents a run emits several
        # result events, and the last one's duration_ms covers only its turn.
        (OUT / f"{cell}.wall").write_text(f"{time.time() - started:.1f}\n")
        helpers = [json.loads(l) for f in sorted((work / ".universe/agents").glob("*.usage.jsonl"))
                   for l in f.read_text().splitlines() if l.strip()]
        if setup == "agents":
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
    a = ap.parse_args()

    tasks, setups = a.tasks.split(","), a.setups.split(",")
    for t in tasks:
        assert t in TASKS, t
    OUT.mkdir(exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    if {"universe", "agents"} & set(setups) and not UCTL.exists():
        sys.exit(f"build the release first: MIX_ENV=prod mix release ({UCTL} missing)")

    for n in range(a.start, a.start + a.runs):
        for task in tasks:
            for setup in setups:
                run_cell(task, setup, n, a.go)
    if not a.go:
        print("\n(dry run — pass --go to launch; this spends Claude plan usage)", file=sys.stderr)


if __name__ == "__main__":
    main()
