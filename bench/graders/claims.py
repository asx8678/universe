"""Grade the benchmark task: decisions.md decides every refund claim.

PASS needs every claim exactly once and at least 95 % of decisions right
(the order id and type are reported, not graded).
"""
import json
import pathlib
import re
import sys

answers = json.loads((pathlib.Path(__file__).parent / "claims_answers.json").read_text())
LINE = re.compile(r"^[\s>*\-+#]*\**(\d+)\**\s*[.:)]\s*\**\s*(approve|deny|escalate)\b[^|]*"
                  r"(?:\|\s*`?([\w-]+)`?[^|]*)?(?:\|\s*#?(\d+))?", re.I)

report = pathlib.Path("decisions.md")
if not report.exists():
    print("FAIL: no decisions.md")
    sys.exit(1)

seen, dupes = {}, 0
for line in report.read_text().splitlines():
    m = LINE.match(line.strip())
    if not m:
        continue
    if m.group(1) in seen:
        dupes += 1
        continue
    seen[m.group(1)] = (m.group(2).lower(), (m.group(3) or "").strip().lower(), m.group(4))

missing = [c for c in answers if c not in seen]
right = sum(1 for c, a in answers.items() if seen.get(c, ("",))[0] == a["decision"])
orders = sum(1 for c, a in answers.items() if c in seen and seen[c][2] == str(a["order"]))
rate = right / len(answers)
print(f"decisions {right}/{len(answers)} ({rate:.1%}), orders identified {orders}/{len(answers)}")
problems = []
if missing:
    problems.append(f"{len(missing)} claims missing")
if dupes:
    problems.append(f"{dupes} duplicated")
if rate < 0.95:
    problems.append(f"decisions {rate:.1%} right (need 95 %)")
print("PASS" if not problems else "FAIL: " + "; ".join(problems))
sys.exit(0 if not problems else 1)
