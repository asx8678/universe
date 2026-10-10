#!/usr/bin/env python3
"""Print (and optionally launch) the claude -p command for one benchmark cell.

    python3 bench/run.py --task summarize --setup universe --runs 3
    python3 bench/run.py --task summarize --setup universe --runs 3 --go

Without --go it only prints the commands and writes nothing: launching dozens
of Claude sessions spends the user's plan, so that is a deliberate step. Each
run writes bench/out/<task>.<setup>.<n>.jsonl, which collect.py reads.
"""

import argparse
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "out"

TASKS = {
    "summarize": "Summarise every module under lib/ into a single index file, index.md, with one line per module (path, purpose, key functions). The modules are independent.",
    "edits": "In each file under lib/, rename the function `old_api` to `new_api` (definition and call sites). The files are independent. Then run the tests with `mix test` and make them pass.",
    "dbchecks": "Run the 20 checks listed in checks.md against data/app.db and write report.md marking each check pass or fail with the number it found.",
}


def command(task, setup, n, project):
    out = OUT / f"{task}.{setup}.{n}.jsonl"
    prompt = TASKS[task]
    args = ["claude", "-p", prompt, "--output-format", "stream-json", "--verbose"]
    if setup == "universe":
        args += ["--plugin-dir", str(ROOT.parent / "plugin" / "universe-plugin")]
    return args, out, project


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--task", required=True, choices=TASKS)
    ap.add_argument("--setup", required=True, choices=["baseline", "universe"])
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--project", default=None, help="fixture working copy (cwd for claude)")
    ap.add_argument("--go", action="store_true", help="actually launch (spends plan usage)")
    a = ap.parse_args()

    OUT.mkdir(exist_ok=True)
    project = a.project or str(ROOT / "fixtures" / a.task)

    for n in range(1, a.runs + 1):
        args, out, cwd = command(a.task, a.setup, n, project)
        printable = " ".join(f'"{x}"' if " " in x else x for x in args)
        print(f"# run {n}: cd {cwd} && {printable} > {out}")
        if a.go:
            with open(out, "w") as f:
                subprocess.run(args, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, check=False)

    if not a.go:
        print("\n(dry run — pass --go to launch; this spends Claude plan usage)", file=sys.stderr)


if __name__ == "__main__":
    main()
