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
    wall_s      real elapsed time from <cell>.wall (run.py), else the sum of
                result.duration_ms
    turns       sum of result.num_turns (background subagents add results)
    success     PASS/FAIL from the grader
"""

import json
import os
import statistics
import sys


def parse(path):
    usage_by_msg = {}
    helper_msgs = set()
    delegations = 0
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
                key = msg.get("id") or id(e)
                usage_by_msg[key] = inp + u.get("output_tokens", 0)
                if e.get("parent_tool_use_id"):
                    helper_msgs.add(key)
                elif inp:
                    main_ctx = inp
                for c in msg.get("content", []):
                    if c.get("type") != "tool_use":
                        continue
                    if c.get("name") == "ToolSearch":
                        tool_search = True
                    elif c.get("name") in ("Agent", "Task"):
                        delegations += 1
                    elif c.get("name") == "mcp__universe__tick":
                        delegations += sum(1 for d in c.get("input", {}).get("directives") or []
                                           if isinstance(d, dict) and d.get("op") == "call" and "prompt" in d)
            elif t == "result":
                # Background subagents make several results per run: sum them.
                turns += e.get("num_turns", 0)
                wall_s += (e.get("duration_ms") or 0) / 1000

    wall_file = path.removesuffix(".jsonl") + ".wall"
    wall_s = float(open(wall_file).read()) if os.path.exists(wall_file) else round(wall_s, 1)
    helpers = sum(v for k, v in usage_by_msg.items() if k in helper_msgs)
    side = path.removesuffix(".jsonl") + ".helpers.json"
    if os.path.exists(side):
        # Universe agent workers run outside this transcript; run.py saved their usage.
        helpers += json.load(open(side))["tokens"]
    orchestrator = sum(v for k, v in usage_by_msg.items() if k not in helper_msgs)
    return {"main_ctx": main_ctx, "total": orchestrator + helpers, "helpers": helpers,
            "wall_s": wall_s, "turns": turns, "model": model, "tool_search": tool_search,
            "delegations": delegations}


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
    print("| Task | Setup | runs | pass | main ctx | total tokens | helper tokens | wall s | turns | delegations |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    cells = {}
    for r in rows:
        cells.setdefault((r["task"], r["setup"]), []).append(r)
    for (task, setup), rs in sorted(cells.items()):
        med = lambda k: statistics.median(r[k] for r in rs)
        print(f"| {task} | {setup} | {len(rs)} | {sum(r['success'] for r in rs)}/{len(rs)} | "
              f"{med('main_ctx'):,.0f} | {med('total'):,.0f} | {med('helpers'):,.0f} | {med('wall_s'):g} | "
              f"{med('turns'):g} | {med('delegations'):g} |")

    if {r["setup"] for r in rows} <= {"subagents", "agents"}:
        verdict_m6(rows, cells)
    else:
        verdict_m4(rows, cells)
    runs_table(rows)


def verdict_m6(rows, cells):
    print("\n## Go / no-go (M6 rule fixed in README.md before the runs)\n")
    m = lambda rs, k: statistics.median(r[k] for r in rs)
    tasks = sorted({r["task"] for r in rows})
    wins = 0
    for task in tasks:
        s, a = cells.get((task, "subagents")), cells.get((task, "agents"))
        if not s or not a:
            print(f"- **{task}:** incomplete")
            continue
        tokens = m(a, "total") / max(m(s, "total"), 1)
        wall = m(a, "wall_s") / max(m(s, "wall_s"), 0.1)
        ctx = m(a, "main_ctx") / max(m(s, "main_ctx"), 1)
        passed = all(r["success"] for r in s + a)
        win = passed and tokens <= 0.8 and wall <= 1.2 and ctx <= 1.1
        wins += win
        print(f"- **{task}:** agents/subagents total tokens {tokens:.0%} (need ≤ 80%), wall {wall:.0%} "
              f"(≤ 120%), main ctx {ctx:.0%} (≤ 110%), all pass: {'yes' if passed else 'no'} "
              f"→ **{'win' if win else 'no win'}**")
    verdict = "GO" if wins == len(tasks) == 2 else "NO-GO"
    print(f"\n**Verdict: {verdict}** ({wins} of {len(tasks)} tasks won; go needs both).\n")


def verdict_m4(rows, cells):
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


def runs_table(rows):
    print("## Runs\n")
    print("| Cell | grade | main ctx | total | helpers | wall s | turns | delegations | ToolSearch |")
    print("|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        print(f"| {r['task']}.{r['setup']}.{r['run']} | {r['grade']} | {r['main_ctx']:,} | {r['total']:,} | "
              f"{r['helpers']:,} | {r['wall_s']:g} | {r['turns']} | {r['delegations']} | "
              f"{'yes' if r['tool_search'] else 'no'} |")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: collect.py bench/out/*.jsonl")
    main([p for p in sys.argv[1:] if p.endswith(".jsonl")])
