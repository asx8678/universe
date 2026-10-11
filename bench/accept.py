#!/usr/bin/env python3
"""Score M7 acceptance runs against the criteria fixed in bench/README.md.

    python3 bench/accept.py bench/out7/triage.accept.*.jsonl

Reads each run's transcript (<cell>.jsonl), the daemon's event log that
run.py copied (<cell>.events.jsonl), the grade, the mid-run marker and the
helpers' usage. Criteria come from the logs, not from what the model says.
"""

import datetime as dt
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from collect import parse  # noqa: E402


def load_jsonl(path):
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path):
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return out


def ts(e):
    return dt.datetime.fromisoformat(e["ts"].replace("Z", "+00:00")).timestamp()


def side(path, ext, default=None):
    p = path.removesuffix(".jsonl") + ext
    return open(p).read().strip() if os.path.exists(p) else default


def tool_uses(transcript):
    for e in transcript:
        if e.get("type") == "assistant" and not e.get("parent_tool_use_id"):
            for c in e.get("message", {}).get("content", []):
                if c.get("type") == "tool_use":
                    yield c


def score(path):
    transcript = load_jsonl(path)
    events = load_jsonl(path.removesuffix(".jsonl") + ".events.jsonl")
    m = parse(path)

    uses = list(tool_uses(transcript))
    ticks = [u["input"].get("directives") or [] for u in uses if u["name"] == "mcp__universe__tick"]
    directives = [d for t in ticks for d in t if isinstance(d, dict)]

    agents_given = {}
    for d in directives:
        if d.get("op") == "serve" and isinstance(d.get("agent"), dict):
            agents_given[d.get("label")] = d["agent"].get("services") or []

    spawns = {e["id"]: e["data"] for e in events if e["type"] == "spawn"}
    agent_ids = {i for i, d in spawns.items() if d.get("lang") == "agent"}
    # Only agents that actually started count (a rejected serve never spawns).
    started = {spawns[i].get("label") for i in agent_ids}
    agents_given = {a: s for a, s in agents_given.items() if a in started}
    code_services = {e["data"].get("name") for e in events
                     if e["type"] == "serve" and e["id"] not in agent_ids}
    wired_agents = {a for a, svcs in agents_given.items() if set(svcs) & code_services}

    sdk_calls = [e for e in events if e["type"] == "call" and e["data"].get("via") == "sdk"]
    agent_tool_calls = [e for e in sdk_calls if e["id"] in agent_ids]
    task_calls = [e for e in events if e["type"] == "queued" and e["data"].get("kind") == "call"]

    # Serve and task in one tick: an agent served and called (by name or pool) together.
    same_tick = any(
        any(d.get("op") == "call" and "prompt" in d and
            d.get("service") in {a.get("label") for a in t if a.get("op") == "serve" and "agent" in a} |
            {a["agent"].get("pool") for a in t if a.get("op") == "serve" and isinstance(a.get("agent"), dict)}
            for d in t)
        for t in ticks)

    # A delegated task stopped by a kill (restarting it instead of steering).
    task_ids = {q["id"] for q in task_calls}
    tasks_killed = sum(1 for e in events
                       if e["type"] == "exit" and e["id"] in task_ids and e["data"].get("status") == "killed")
    steers_sent = [d for d in directives if d.get("op") == "steer"]
    steers_ok = [e for e in events if e["type"] == "steer"]
    steers_rejected = [e["data"].get("reason") for e in events
                       if e["type"] == "rejected" and e["data"].get("op") == "steer"]

    midrun = json.loads(side(path, ".midrun", "null") or "null")
    window = None
    if midrun and events:
        at = midrun["at"]
        # A task was in flight when the message went in: started before, ended after.
        ended = {e["id"]: ts(e) for e in events if e["type"] == "exit"}
        window = any(ts(q) <= at and ended.get(q["id"], float("inf")) > at for q in task_calls)
        if not window:
            starts = [ts(e) for e in sdk_calls if "prompt" in e["data"] and "ok" not in e["data"]]
            dones = [ts(e) for e in events if e["type"] == "call_done"]
            window = sum(s <= at for s in starts) > sum(d <= at for d in dones)

    # Run output pulled into the main context with Read (the do-it-myself path).
    reads = {u["id"] for u in uses if u["name"] == "Read" and ".universe/runs/" in str(u["input"].get("file_path"))}
    read_chars = 0
    for e in transcript:
        if e.get("type") == "user" and isinstance(e.get("message", {}).get("content"), list):
            for c in e["message"]["content"]:
                if c.get("type") == "tool_result" and c.get("tool_use_id") in reads:
                    body = c["content"]
                    read_chars += len(body) if isinstance(body, str) else sum(len(x.get("text", "")) for x in body)

    helpers = json.loads(side(path, ".helpers.json", "null") or "null") or {}
    grade = side(path, ".grade", "?")
    return {
        "cell": os.path.basename(path).removesuffix(".jsonl"),
        "grade": grade,
        "built": bool(wired_agents),
        "agents": len(agent_ids),
        "code_services": sorted(n for n in code_services if n),
        "wired": len(agent_tool_calls),
        "same_tick": same_tick,
        "inspect_first": bool(uses) and uses[0]["name"] == "mcp__universe__inspect",
        "midrun": midrun and f"{midrun['after_s']:.0f}s ({midrun['why']})",
        "window": window,
        "steers": f"{len(steers_ok)} delivered / {len(steers_sent)} sent",
        "steer_rejections": steers_rejected,
        "tasks": len(task_calls),
        "tasks_killed": tasks_killed,
        "run_output_read_tok": read_chars // 4,
        "turns": m["turns"],
        "orch_tokens": m["total"] - m["helpers"],
        "helper_tokens": m["helpers"],
        "helper_models": helpers.get("models"),
        "main_ctx": m["main_ctx"],
        "wall_s": m["wall_s"],
        "model": m["model"],
    }


def steer_verdict(r):
    """Steer acceptance: a delivered steer, the task not killed, review graded."""
    return r["grade"] == "PASS" and r["steers"].split()[0] != "0" and r["tasks_killed"] == 0


def verdict(r):
    passed = r["grade"] == "PASS" and r["built"] and r["wired"] > 0 and r["turns"] <= 25
    steer = "n/a (no window)" if r["window"] is False else (
        "yes" if r["steers"].split()[0] != "0" else "no")
    turns = "fail-worthy" if r["turns"] > 25 else "flag" if r["turns"] > 15 else "ok"
    return passed, steer, turns


def main():
    rows = [score(p) for p in sys.argv[1:] if not p.endswith(".events.jsonl")]
    print("| run | grade | built | wired calls | serve+task 1 tick | mid-run | window | steers | tasks | turns | orch tok | helper tok | wall s |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        print(f"| {r['cell']} | {r['grade']} | {r['built']} ({r['agents']} agents, {', '.join(r['code_services']) or '-'}) "
              f"| {r['wired']} | {r['same_tick']} | {r['midrun']} | {r['window']} | {r['steers']} | {r['tasks']} "
              f"| {r['turns']} | {r['orch_tokens']:,} | {r['helper_tokens']:,} | {r['wall_s']:.0f} |")
    print()
    if all(r["cell"].startswith("review.") for r in rows):
        for r in rows:
            print(f"- {r['cell']}: {'PASS' if steer_verdict(r) else 'FAIL'} (steer delivered, task not killed, "
                  f"review graded) · steers {r['steers']} · tasks killed {r['tasks_killed']} · grade {r['grade']}"
                  f" · window {r['window']} · turns {r['turns']}"
                  + (f" · steer rejections: {r['steer_rejections']}" if r["steer_rejections"] else ""))
        return
    for r in rows:
        passed, steer, turns = verdict(r)
        print(f"- {r['cell']}: {'PASS' if passed else 'FAIL'} (built, wired, correct, <= 25 turns) · steered: {steer} · turns {r['turns']} ({turns})"
              f" · model {r['model']}, helpers {r['helper_models']} · inspect first: {r['inspect_first']}"
              + f" · run output Read into context ~{r['run_output_read_tok']:,} tokens"
              + (f" · steer rejections: {r['steer_rejections']}" if r["steer_rejections"] else ""))


if __name__ == "__main__":
    main()
