#!/usr/bin/env python3
"""Gates for the triage fixture's open tickets, before any acceptance run.

    python3 bench/audit_triage.py [--skip-clarity] [--skip-regex]

1. Clarity: haiku, reading each ticket with the category definitions and the
   chargeback rule, must agree with the label. Disagreements are listed for
   `write_tickets.py --only ...` to rewrite.
2. No regex shortcut (the pilot's path): sonnet sees 50 labelled tickets and
   writes a keyword/regex classifier; on all tickets it must get <= 93 % of
   categories (two points under the grader's 95 % bar), and miss or wrongly
   flag at least 10 % as many tickets as really mention a chargeback. Run it
   with two samples (--seed).
3. No shortcut from the labelled history: a naive Bayes classifier trained on
   the closed tickets' text and `category` (which the model can read in the
   database) must get <= 93 % of the open tickets' categories.

Reads bench/graders/triage_{specs,bodies}.json; spends Claude usage.
"""

import argparse
import json
import pathlib
import random
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

BENCH = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(BENCH))
from write_tickets import CATEGORIES  # noqa: E402

SPECS = json.loads((BENCH / "graders" / "triage_specs.json").read_text())
BODIES = json.loads((BENCH / "graders" / "triage_bodies.json").read_text())
RULE = ("a ticket mentions a chargeback if the customer says they filed or will file a chargeback, or have asked "
        "or will ask their bank or card issuer to dispute, reverse or pull back the payment")


def claude(model, prompt, timeout=900):
    return subprocess.run(["claude", "-p", "--model", model, "--tools", "", "--strict-mcp-config"],
                          input=prompt, capture_output=True, text=True, timeout=timeout).stdout


def label(t):
    return SPECS[t]["category"], SPECS[t]["chargeback"] != "none"


def clarity():
    ids = sorted(BODIES)
    batches = [ids[i:i + 50] for i in range(0, len(ids), 50)]

    def run(batch):
        prompt = (f"Classify each support ticket. Categories (the problem the customer wants solved now):\n"
                  f"{CATEGORIES}\n\nChargeback: yes if {RULE}; otherwise no.\n"
                  "Answer with one line per ticket, `<id> <category> <yes|no>`, nothing else.\n\n" +
                  "\n\n".join(f"Ticket {t}:\n{BODIES[t]}" for t in batch))
        out = claude("haiku", prompt)
        return {m.group(1): (m.group(2), m.group(3) == "yes")
                for m in re.finditer(r"(\d+)\s+([a-z_]+)\s+(yes|no)", out)}

    got = {}
    with ThreadPoolExecutor(6) as pool:
        for g in pool.map(run, batches):
            got.update(g)
    bad = [t for t in ids if got.get(t) != label(t)]
    for t in bad:
        print(f"  {t}: label {label(t)}, haiku {got.get(t)}")
    print(f"clarity: {len(ids) - len(bad)}/{len(ids)} agree")
    return bad


def regex_gate(seed):
    r = random.Random(seed)
    sample = r.sample(sorted(BODIES), 50)
    shown = "\n\n".join(f"--- category={SPECS[t]['category']} chargeback={label(t)[1]}\n{BODIES[t]}" for t in sample)
    prompt = ("Here are 50 labelled customer support tickets. Write a Python 3 module (standard library only) "
              "with a function `classify(body: str) -> tuple[str, bool]` returning the category and whether the "
              "ticket mentions a chargeback, using keywords and regular expressions; make it as accurate as you can "
              f"on unseen tickets of the same kind. Categories:\n{CATEGORIES}\nChargeback rule: {RULE}.\n\n{shown}\n\n"
              "Answer with only the code in one ```python block.")
    out = claude("sonnet", prompt)
    m = re.search(r"```python\n(.*?)```", out, re.S)
    if not m:
        sys.exit("regex gate: no code came back")
    with tempfile.TemporaryDirectory() as d:
        pathlib.Path(d, "clf.py").write_text(m.group(1))
        pathlib.Path(d, "bodies.json").write_text(json.dumps(BODIES))
        runner = ("import json, sys\nsys.path.insert(0, '.')\nimport clf\nb = json.load(open('bodies.json'))\n"
                  "print(json.dumps({t: list(clf.classify(x)) for t, x in b.items()}))")
        res = subprocess.run([sys.executable, "-I", "-c", runner], cwd=d, capture_output=True, text=True, timeout=120)
    (BENCH / "graders" / f"triage_regex_gate_{seed}.py").write_text(m.group(1))
    if res.returncode != 0:
        sys.exit("regex gate: the classifier failed:\n" + res.stderr[-2000:])
    preds = json.loads(res.stdout)
    cat = sum(preds[t][0] == SPECS[t]["category"] for t in BODIES) / len(BODIES)
    positives = sum(label(t)[1] for t in BODIES)
    cb_errors = sum(bool(preds[t][1]) != label(t)[1] for t in BODIES)
    ok = cat <= 0.93 and cb_errors >= 0.1 * positives
    print(f"regex gate (seed {seed}): categories {cat:.1%} (need <= 93 %), chargeback errors {cb_errors} of {positives} "
          f"positives (need >= {0.1 * positives:.0f}) -> {'PASS' if ok else 'FAIL'}")
    return ok


def history_gate():
    import collections
    import math
    import sqlite3

    db = sqlite3.connect(BENCH / "fixtures" / "triage" / "data" / "support.db")
    words = lambda t: re.findall(r"[a-z']+", t.lower())  # noqa: E731
    counts = collections.defaultdict(collections.Counter)
    docs = collections.Counter()
    for body, cat in db.execute("select body, category from tickets where status = 'closed'"):
        docs[cat] += 1
        counts[cat].update(set(words(body)))
    vocab = set().union(*counts.values())

    def predict(body):
        ws = set(words(body)) & vocab
        return max(counts, key=lambda c: math.log(docs[c]) + sum(
            math.log((counts[c][w] + 1) / (docs[c] + 2)) for w in ws))

    right = sum(predict(BODIES[t]) == SPECS[t]["category"] for t in BODIES) / len(BODIES)
    ok = right <= 0.93
    print(f"history gate: naive Bayes on {sum(docs.values())} closed tickets gets {right:.1%} of open "
          f"categories (need <= 93 %) -> {'PASS' if ok else 'FAIL'}")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-clarity", action="store_true")
    ap.add_argument("--skip-regex", action="store_true")
    ap.add_argument("--seeds", default="1,2", help="samples for the regex gate")
    a = ap.parse_args()
    bad = [] if a.skip_clarity else clarity()
    ok = history_gate()
    if not a.skip_regex:
        for seed in map(int, a.seeds.split(",")):
            ok = regex_gate(seed) and ok
    if bad:
        print("rewrite: python3 bench/write_tickets.py --only " + ",".join(bad))
    sys.exit(0 if ok and not bad else 1)


if __name__ == "__main__":
    main()
