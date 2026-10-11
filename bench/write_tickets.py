#!/usr/bin/env python3
"""Write the open tickets' bodies for the triage fixture with an LLM, once.

    python3 bench/write_tickets.py [--model sonnet] [--only 1234,1235]

Reads bench/graders/triage_specs.json (from gen_triage.py) and fills
bench/graders/triage_bodies.json, 20 tickets per `claude -p` call, a few calls
at a time. Resumable: tickets already written are skipped; --only rewrites the
given ones (the audit's rejects). Spends Claude usage (~$3 for 600 tickets).
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor

BENCH = pathlib.Path(__file__).resolve().parent
SPECS = BENCH / "graders" / "triage_specs.json"
BODIES = BENCH / "graders" / "triage_bodies.json"
BATCH = 20

CATEGORIES = """- billing: wrong, double or unexpected charges, invoices, refunds of money already paid
- shipping: late, lost, misdelivered parcels, tracking, delivery address
- account: signing in, passwords, two-factor, account details
- bug: something in the app or website is broken
- returns: sending items back, exchanges, return labels
- feature_request: asking for something the product doesn't do yet"""

PROMPT = """You write realistic customer support emails for a test dataset of an online shop.
The categories are:

{categories}

Write one email per spec below. Rules:
- The customer's real problem (the thing they want solved now) must clearly belong to
  the spec's `category` and to no other; invent a specific, varied problem (not the
  first example that comes to mind; vary products, symptoms and details).
- Mention each category in `asides` only in passing, so it is clearly NOT the problem:
  a past problem that was already resolved ("unlike the double charge last spring,
  which you sorted quickly"), a compliment, or background. Use that category's
  natural vocabulary there, so keyword matching would be misleading.
- `chargeback`: "none" means no mention of chargebacks, disputing charges or
  reversing payments through a bank or card company at all. "direct" means the
  customer says they filed or will file a chargeback, using that word. "indirect"
  means they say they have asked, or will ask, their bank or card company to reverse,
  dispute or pull back the payment, WITHOUT the words "chargeback" or "dispute".
- Write as the `persona`, about `length` characters (±15 %). Sign with `first_name`.
  Use `order`, `item` and `date` where natural.
- If `issue_last` is true, spend the first paragraphs on background and asides and
  state the real problem only in the last paragraph.
- Vary openings, structure and wording across emails; never reuse a sentence.
- No subject line, no headers, plain text only.

Specs (JSON, keyed by ticket id):
{specs}

Answer with ONLY a JSON object mapping each ticket id to its email text."""

lock = threading.Lock()


def write_batch(ids, specs, model, bodies):
    batch = {i: {k: v for k, v in specs[i].items()} for i in ids}
    prompt = PROMPT.format(categories=CATEGORIES, specs=json.dumps(batch, indent=1))
    for attempt in range(3):
        out = subprocess.run(["claude", "-p", "--model", model, "--tools", "", "--strict-mcp-config"],
                             input=prompt, capture_output=True, text=True, timeout=900).stdout
        m = re.search(r"\{.*\}", out, re.S)
        try:
            got = json.loads(m.group(0)) if m else {}
        except json.JSONDecodeError:
            got = {}
        got = {k: v.strip() for k, v in got.items() if k in batch and isinstance(v, str) and len(v) > 200}
        if len(got) == len(ids):
            break
        print(f"  batch {ids[0]}: {len(got)}/{len(ids)} on attempt {attempt + 1}", flush=True)
    with lock:
        bodies.update(got)
        BODIES.write_text(json.dumps(bodies, indent=1, ensure_ascii=False) + "\n")
    print(f"batch {ids[0]}..{ids[-1]}: {len(got)} written ({len(bodies)} total)", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--only", help="comma-separated ticket ids to (re)write")
    ap.add_argument("--jobs", type=int, default=6)
    a = ap.parse_args()

    specs = json.loads(SPECS.read_text())
    bodies = json.loads(BODIES.read_text()) if BODIES.exists() else {}
    if a.only:
        todo = a.only.split(",")
        for t in todo:
            bodies.pop(t, None)
    else:
        todo = [t for t in specs if t not in bodies]
    if not todo:
        sys.exit("all bodies written")
    batches = [todo[i:i + BATCH] for i in range(0, len(todo), BATCH)]
    print(f"{len(todo)} tickets in {len(batches)} batches with {a.model}", flush=True)
    with ThreadPoolExecutor(a.jobs) as pool:
        for b in batches:
            pool.submit(write_batch, b, specs, a.model, bodies)


if __name__ == "__main__":
    main()
