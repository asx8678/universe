#!/usr/bin/env python3
"""Turn benchmark transcripts into RESULTS.md.

    python3 bench/collect.py bench/out/*.jsonl > bench/RESULTS.md

Each run is `<task>.<setup>.<n>.jsonl` (claude -p stream-json) with a
`<task>.<setup>.<n>.grade` next to it. Per run:

    main_ctx    input tokens (incl. cache) of the last main-thread assistant
                message: what the model still carries at the end
    total       input+output tokens summed over every model call, subagents
                included (each message counted once: stream-json repeats a
                message's usage for every content block)
    wall_s      result.duration_ms
    turns       result.num_turns
    success     PASS/FAIL from the grader
"""

import json
import os
import statistics
import sys


def parse(path):
    usage_by_msg = {}
    main_ctx = 0
    wall_s = turns = 0
    model = "?"
    tool_search = False

    with open(path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = e.get("type")
            if t == "system" and e.get("subtype") == "init":
                model = e.get("model", model)
            elif t == "assistant":
                msg = e.get("message", {})
                u = msg.get("usage") or {}
                inp = u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
                usage_by_msg[msg.get("id") or id(e)] = inp + u.get("output_tokens", 0)
                if inp and not e.get("parent_tool_use_id"):
                    main_ctx = inp
                for c in msg.get("content", []):
                    if c.get("type") == "tool_use" and c.get("name") == "ToolSearch":
                        tool_search = True
            elif t == "result":
                turns = e.get("num_turns", 0)
                wall_s = round((e.get("duration_ms") or 0) / 1000, 1)

    return {"main_ctx": main_ctx, "total": sum(usage_by_msg.values()), "wall_s": wall_s,
            "turns": turns, "model": model, "tool_search": tool_search}


def main(paths):
    rows = []
    for p in sorted(paths):
        task, setup, n = os.path.basename(p).removesuffix(".jsonl").split(".")[:3]
        grade_path = p.removesuffix(".jsonl") + ".grade"
        grade = open(grade_path).read().strip() if os.path.exists(grade_path) else "?"
        rows.append({"task": task, "setup": setup, "run": int(n), "success": grade.startswith("PASS"),
                     "grade": grade, **parse(p)})

    print("# Benchmark results\n")
    models = sorted({r["model"] for r in rows})
    print(f"Model: {', '.join(models)}. Medians per cell; token counts from the API usage in each transcript.\n")
    print("| Task | Setup | runs | pass | main ctx | total tokens | wall s | turns |")
    print("|---|---|---|---|---|---|---|---|")
    cells = {}
    for r in rows:
        cells.setdefault((r["task"], r["setup"]), []).append(r)
    for (task, setup), rs in sorted(cells.items()):
        med = lambda k: statistics.median(r[k] for r in rs)
        print(f"| {task} | {setup} | {len(rs)} | {sum(r['success'] for r in rs)}/{len(rs)} | "
              f"{med('main_ctx'):,.0f} | {med('total'):,.0f} | {med('wall_s'):g} | {med('turns'):g} |")

    print("\n## Go / no-go (rule fixed in README.md before the runs)\n")
    wins = 0
    for task in sorted({r["task"] for r in rows}):
        b, u = cells.get((task, "baseline")), cells.get((task, "universe"))
        if not b or not u:
            print(f"- **{task}:** incomplete")
            continue
        m = lambda rs, k: statistics.median(r[k] for r in rs)
        ctx_cut = 1 - m(u, "main_ctx") / max(m(b, "main_ctx"), 1)
        faster_or_cheaper = m(u, "wall_s") < m(b, "wall_s") or m(u, "total") < m(b, "total")
        equal_success = all(r["success"] for r in b + u)
        win = ctx_cut >= 0.5 and faster_or_cheaper and equal_success
        wins += win
        print(f"- **{task}:** main-context cut {ctx_cut:.0%}, faster or cheaper: {'yes' if faster_or_cheaper else 'no'}, "
              f"all runs pass: {'yes' if equal_success else 'no'} → **{'win' if win else 'no win'}**")
    verdict = "GO" if wins >= 2 else "NO-GO"
    print(f"\n**Verdict: {verdict}** ({wins} of {len(set(r['task'] for r in rows))} tasks won; go needs 2).\n")

    print("## Runs\n")
    print("| Cell | grade | main ctx | total | wall s | turns | ToolSearch |")
    print("|---|---|---|---|---|---|---|")
    for r in rows:
        print(f"| {r['task']}.{r['setup']}.{r['run']} | {r['grade']} | {r['main_ctx']:,} | {r['total']:,} | "
              f"{r['wall_s']:g} | {r['turns']} | {'yes' if r['tool_search'] else 'no'} |")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: collect.py bench/out/*.jsonl")
    main([p for p in sys.argv[1:] if p.endswith(".jsonl")])
