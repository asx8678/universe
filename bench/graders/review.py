"""Grade the steer acceptance task: review.md after a mid-run change of brief.

The change (sent mid-run) adds docstring defects (kind `docstring`) and says
to skip web/ from then on. PASS needs at least 80 % of the docstring defects
outside web/ found (they sit only in files reviewed after the change) and at
most 2 findings in web/ (every web/ file comes after it). Line-level bugs of
the first brief are reported, not graded.
"""
import json
import pathlib
import re
import sys

answers = json.loads((pathlib.Path(__file__).parent / "review_answers.json").read_text())
LINE = re.compile(r"^[\s>*\-+`]*([\w./-]+\.py)\s*::\s*`?(\w+)`?\s*\|\s*`?([\w -]+?)`?\s*(\||$)")

report = pathlib.Path("review.md")
if not report.exists():
    print("FAIL: no review.md")
    sys.exit(1)

found = []
for line in report.read_text().splitlines():
    m = LINE.match(line.strip())
    if m:
        found.append((m.group(1), m.group(2), m.group(3).strip().lower()))

doc = {(p, f) for p, f, k in found if "doc" in k}
y = {(a["path"], a["function"]) for a in answers["y"]}
x = {(a["path"], a["function"]) for a in answers["x"]}
y_found = len(y & doc)
web_findings = sum(1 for p, _, _ in found if p.startswith("web/"))
x_found = len(x & {(p, f) for p, f, k in found if "doc" not in k})
false_doc = len(doc - y - {(a["path"], a["function"]) for a in answers["web_y"]})

recall = y_found / len(y)
print(f"docstring defects {y_found}/{len(y)} ({recall:.0%}), web/ findings {web_findings}, "
      f"line-level bugs {x_found}/{len(x)}, docstring false positives {false_doc}")
problems = []
if recall < 0.8:
    problems.append(f"docstring defects {recall:.0%} found (need 80 %)")
if web_findings > 2:
    problems.append(f"{web_findings} findings in web/ (at most 2)")
print("PASS" if not problems else "FAIL: " + "; ".join(problems))
sys.exit(0 if not problems else 1)
