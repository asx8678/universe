#!/usr/bin/env python3
"""Gates for the benchmark fixture (refund claims), before any run.

    python3 bench/audit_claims.py [--skip-clear] [--skip-blind] [--skip-script]

1. clear: haiku, given a claim, the policy and that customer's records,
   decides as the answer key does on >= 97 % of claims (labels are sound).
2. blind: haiku, given only the claim text and the policy, gets < 70 %
   (the records are needed).
3. script: sonnet sees 50 labelled claims plus the schema and writes a
   regex-and-SQL solver; on all claims it must get < 85 % (no shortcut
   around reading each claim with the records).
"""

import argparse
import json
import pathlib
import random
import re
import sqlite3
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

BENCH = pathlib.Path(__file__).resolve().parent
FIX = BENCH / "fixtures" / "claims"
ANSWERS = json.loads((BENCH / "graders" / "claims_answers.json").read_text())
POLICY = (FIX / "policy.md").read_text()
DB = FIX / "data" / "shop.db"


def claude(model, prompt):
    return subprocess.run(["claude", "-p", "--model", model, "--tools", "", "--strict-mcp-config"],
                          input=prompt, capture_output=True, text=True, timeout=900).stdout


def records(db, cid):
    rows = lambda q: [dict(zip([d[0] for d in c.description], r)) for c in [db.execute(q, (cid,))] for r in c]  # noqa
    return {
        "customer": rows("select * from customers where id=?"),
        "orders": rows("select * from orders where customer_id=?"),
        "shipments": rows("select s.* from shipments s join orders o on o.id=s.order_id where o.customer_id=?"),
        "payments": rows("select p.* from payments p join orders o on o.id=p.order_id where o.customer_id=?"),
        "refunds": rows("select r.* from refunds r join orders o on o.id=r.order_id where o.customer_id=?"),
    }


def decide_batches(model, with_records):
    db = sqlite3.connect(DB)
    claims = db.execute("select id, customer_id, body from claims order by id").fetchall()
    batches = [claims[i:i + 15] for i in range(0, len(claims), 15)]

    def run(batch):
        parts = []
        for cid_claim, cust, body in batch:
            extra = f"\nRecords: {json.dumps(records(db_local(), cust))}" if with_records else ""
            parts.append(f"Claim {cid_claim} (customer {cust}):\n{body}{extra}")
        prompt = (f"{POLICY}\n\nDecide each claim below by the policy."
                  + ("" if with_records else " You have no access to the records; decide as best you can.")
                  + " Answer with one line per claim: `<claim id> <approve|deny|escalate>`, nothing else.\n\n"
                  + "\n\n".join(parts))
        out = claude(model, prompt)
        return {m.group(1): m.group(2) for m in re.finditer(r"(\d{4,})\W+(approve|deny|escalate)", out)}

    got = {}
    with ThreadPoolExecutor(6) as pool:
        for g in pool.map(run, batches):
            got.update(g)
    right = [c for c, a in ANSWERS.items() if got.get(c) == a["decision"]]
    return len(right) / len(ANSWERS), [c for c in ANSWERS if got.get(c) != ANSWERS[c]["decision"]]


def db_local():
    return sqlite3.connect(DB)


def script_gate(seed=1):
    r = random.Random(seed)
    db = sqlite3.connect(DB)
    sample = r.sample(sorted(ANSWERS), 50)
    shown = "\n\n".join(
        f"--- claim {c}: decision={ANSWERS[c]['decision']} type={ANSWERS[c]['type']} order={ANSWERS[c]['order']}\n"
        + db.execute("select body from claims where id=?", (int(c),)).fetchone()[0] for c in sample)
    schema = "\n".join(r[0] for r in db.execute("select sql from sqlite_master where type='table'"))
    prompt = (f"{POLICY}\n\nSchema:\n{schema}\n\nHere are 50 labelled claims. Write a Python 3 module "
              "(standard library only) with `decide(db_path: str) -> dict[int, str]` that decides every claim "
              "in the claims table by the policy, using regular expressions on the claim text and SQL on the "
              "records, as accurately as you can on unseen claims of the same kind.\n\n" + shown +
              "\n\nAnswer with only the code in one ```python block.")
    out = claude("sonnet", prompt)
    m = re.search(r"```python\n(.*?)```", out, re.S)
    if not m:
        sys.exit("script gate: no code came back")
    (BENCH / "graders" / f"claims_script_gate_{seed}.py").write_text(m.group(1))
    with tempfile.TemporaryDirectory() as d:
        pathlib.Path(d, "solver.py").write_text(m.group(1))
        runner = ("import json, sys\nsys.path.insert(0, '.')\nimport solver\n"
                  f"print(json.dumps({{str(k): v for k, v in solver.decide({str(DB)!r}).items()}}))")
        res = subprocess.run([sys.executable, "-I", "-c", runner], cwd=d, capture_output=True, text=True,
                             timeout=300)
    if res.returncode != 0:
        sys.exit("script gate: the solver failed:\n" + res.stderr[-2000:])
    got = json.loads(res.stdout)
    rate = sum(got.get(c) == a["decision"] for c, a in ANSWERS.items()) / len(ANSWERS)
    print(f"script gate (seed {seed}): {rate:.1%} (need < 85 %) -> {'PASS' if rate < 0.85 else 'FAIL'}")
    return rate < 0.85


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-clear", action="store_true")
    ap.add_argument("--skip-blind", action="store_true")
    ap.add_argument("--skip-script", action="store_true")
    a = ap.parse_args()
    ok = True
    if not a.skip_clear:
        rate, bad = decide_batches("haiku", True)
        print(f"clear gate: haiku with records {rate:.1%} (need >= 97 %) -> {'PASS' if rate >= 0.97 else 'FAIL'}")
        if bad:
            print("  disagreements: " + ", ".join(bad[:40]))
        ok = ok and rate >= 0.97
    if not a.skip_blind:
        rate, _ = decide_batches("haiku", False)
        print(f"blind gate: haiku without records {rate:.1%} (need < 70 %) -> {'PASS' if rate < 0.7 else 'FAIL'}")
        ok = ok and rate < 0.7
    if not a.skip_script:
        ok = script_gate() and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
