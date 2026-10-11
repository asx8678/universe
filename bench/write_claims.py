#!/usr/bin/env python3
"""Write the refund claims' text for the benchmark fixture with an LLM, once.

    python3 bench/write_claims.py [--model sonnet] [--only 9001,9002]

Reads bench/graders/claims_specs.json (from gen_claims.py) and fills
bench/graders/claims_bodies.json, 20 claims per `claude -p` call. Resumable;
--only rewrites the given ones. Spends Claude usage (~$2).
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
SPECS = BENCH / "graders" / "claims_specs.json"
BODIES = BENCH / "graders" / "claims_bodies.json"
BATCH = 20

CATEGORIES = """- late: it came later than the date promised at checkout
- defect: it arrived broken, faulty or stopped working
- duplicate: the customer was charged twice for it
- wrong_item: a different product was sent than the one ordered
- not_received: it never arrived (or the tracking says delivered but it isn't there)"""

PROMPT = """You write realistic refund claims customers send to an online shop, for a test
dataset. Claim types:

{categories}

Write one claim per spec below. Rules:
- The claim is about the spec's `type`, stated in the customer's own words (never
  the type's name as a label), clearly that type and no other.
- Refer to the order exactly as `order_ref` gives it: an order number, or a loose
  product description and a rough date. Don't invent order numbers.
- If `other_order` is set, also mention that order in passing (it went fine, or
  it is a past purchase), clearly not the subject of the claim.
- If `indirect` is true, never use the obvious words for the problem (late,
  delayed, broken, faulty, defect, charged twice, duplicate, wrong item, never
  arrived, missing): describe what happened instead ("it turned up the day after
  the party", "two identical lines on my statement").
- If `exception` is "gift": the customer mentions, in passing, that they had it
  sent to a friend's or relative's address. If "customer_caused": they admit in
  passing that it broke after they dropped or misused it. Never state either as
  a reason to refuse; it is just part of their story.
- Don't state exact delivery or promised dates, amounts or addresses: the shop
  checks those in its records. Feelings, context and a request (refund, replacement)
  are fine. Some customers mention side details (a gift, a trip, a past order).
- Write as the `persona`, about `length` characters (±15 %). Sign with `first_name`.
- Vary openings and wording across claims; never reuse a sentence. Plain text, no
  subject line.

Specs (JSON, keyed by claim id):
{specs}

Answer with ONLY a JSON object mapping each claim id to its text."""

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
        got = {k: v.strip() for k, v in got.items() if k in batch and isinstance(v, str) and len(v) > 120}
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
