#!/usr/bin/env python3
"""Parse `claude -p --output-format stream-json` transcripts into metrics.

    python3 bench/collect.py bench/out/*.jsonl > bench/RESULTS.md

Each input file is one run, named `<task>.<setup>.<n>.jsonl`. Emits a Markdown
table (and the raw rows as JSON on stderr) with, per run:

    main_context_tokens  input tokens of the final assistant message
    total_tokens         summed input+output over the run
    wall_s               from the result event's duration
    turns                num_turns from the result event
    cost_usd             total_cost_usd (an API-price estimate; 0 on a plan)

`success` is not inferred here; fill it from each fixture's grade.py.
"""

import json
import os
import statistics
import sys


def parse(path):
    main_ctx = 0
    total = 0
    wall_s = turns = 0
    cost = 0.0

    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue

            if e.get("type") == "assistant":
                u = e.get("message", {}).get("usage") or {}
                inp = (u.get("input_tokens", 0)
                       + u.get("cache_read_input_tokens", 0)
                       + u.get("cache_creation_input_tokens", 0))
                out = u.get("output_tokens", 0)
                total += inp + out
                if inp:
                    main_ctx = inp  # last assistant turn wins
            elif e.get("type") == "result":
                turns = e.get("num_turns", turns)
                cost = e.get("total_cost_usd", cost) or 0.0
                ms = e.get("duration_ms")
                if ms:
                    wall_s = round(ms / 1000, 1)

    return {
        "main_context_tokens": main_ctx,
        "total_tokens": total,
        "wall_s": wall_s,
        "turns": turns,
        "cost_usd": round(cost, 4),
    }


def cell(name):
    base = os.path.basename(name).removesuffix(".jsonl")
    parts = base.split(".")
    return (parts[0], parts[1]) if len(parts) >= 2 else (base, "?")


def main(paths):
    rows = []
    for p in paths:
        task, setup = cell(p)
        rows.append({"task": task, "setup": setup, **parse(p)})

    print(json.dumps(rows, indent=2), file=sys.stderr)

    metrics = ["main_context_tokens", "total_tokens", "wall_s", "turns", "cost_usd"]
    groups = {}
    for r in rows:
        groups.setdefault((r["task"], r["setup"]), []).append(r)

    print("# Benchmark results\n")
    print("Median over the runs in each cell.\n")
    print("| Task | Setup | " + " | ".join(metrics) + " | runs |")
    print("|" + "---|" * (len(metrics) + 3))
    for (task, setup), rs in sorted(groups.items()):
        meds = [statistics.median(r[m] for r in rs) for m in metrics]
        print(f"| {task} | {setup} | " + " | ".join(f"{m:g}" for m in meds) + f" | {len(rs)} |")

    print("\n_Fill `success` per task from each fixture's grade.py, then apply the go/no-go rule in README.md._")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: collect.py <run>.jsonl ...")
    main(sys.argv[1:])
