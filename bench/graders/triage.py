"""Grade the M7 acceptance task: triage.md has one line per open ticket.

PASS needs every open ticket exactly once, every priority right (the
chargeback rule sent mid-run included: such tickets are `urgent`), and at
least 95 % of categories right (a keyword classifier tuned on labelled
tickets reached 93 %; see bench/README.md). The next action is not graded.
"""
import json
import pathlib
import re
import sys

answers = json.loads((pathlib.Path(__file__).parent / "triage_answers.json").read_text())
CATEGORIES = {"billing", "shipping", "account", "bug", "returns", "feature_request"}
PRIORITIES = {"urgent", "high", "medium", "low"}
LINE = re.compile(r"^[\s>*\-+#]*\**(\d+)\**\s*[.:)]\s*\**\s*([A-Za-z _-]+?)\s*\**\s*\|\s*\**\s*([A-Za-z]+)\s*\**\s*(\||$)")

report = pathlib.Path("triage.md")
if not report.exists():
    print("FAIL: no triage.md")
    sys.exit(1)

seen = {}
dupes = []
for line in report.read_text().splitlines():
    m = LINE.match(line)
    if not m:
        continue
    tid = m.group(1)
    cat = m.group(2).strip().lower().replace(" ", "_").replace("-", "_")
    pri = m.group(3).strip().lower()
    if tid in seen:
        dupes.append(tid)
    else:
        seen[tid] = (cat, pri)

missing = [t for t in answers if t not in seen]
extra = [t for t in seen if t not in answers]


def want_priority(a):
    return "urgent" if a["chargeback"] else a["priority"]


cat_ok = sum(1 for t, a in answers.items() if seen.get(t, (None,))[0] == a["category"])
pri_wrong = [t for t, a in answers.items() if t in seen and seen[t][1] != want_priority(a)]
cb_wrong = [t for t in pri_wrong if answers[t]["chargeback"] or seen[t][1] == "urgent"]
cat_rate = cat_ok / len(answers)

problems = []
if missing:
    problems.append(f"{len(missing)} missing")
if extra:
    problems.append(f"{len(extra)} not open tickets")
if dupes:
    problems.append(f"{len(dupes)} duplicated")
if pri_wrong:
    problems.append(f"{len(pri_wrong)} priorities wrong ({len(cb_wrong)} on the chargeback rule)")
if cat_rate < 0.95:
    problems.append(f"categories {cat_rate:.0%} right (need 95 %)")

summary = f"categories {cat_ok}/{len(answers)}, priorities {len(answers) - len(missing) - len(pri_wrong)}/{len(answers)}"
print(f"{summary}")
print("PASS" if not problems else "FAIL: " + "; ".join(problems))
sys.exit(0 if not problems else 1)
