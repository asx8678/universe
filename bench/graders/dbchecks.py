"""Grade task 3: report.md has `N. VALUE` for all 20 checks, each correct (±0.01)."""
import json
import pathlib
import re
import sys

answers = json.loads((pathlib.Path(__file__).parent / "dbchecks_answers.json").read_text())
report = pathlib.Path("report.md")
if not report.exists():
    print("FAIL: no report.md"); sys.exit(1)

found = {}
for line in report.read_text().splitlines():
    m = re.match(r"^\s*(\d+)\.\s*\**\s*([-\d.,]+)", line)
    if m:
        found[m.group(1)] = float(m.group(2).replace(",", "").rstrip("."))

wrong = [n for n, v in answers.items() if n not in found or abs(found[n] - float(v)) > 0.011]
print("PASS" if not wrong else f"FAIL: wrong or missing {wrong}")
sys.exit(0 if not wrong else 1)
