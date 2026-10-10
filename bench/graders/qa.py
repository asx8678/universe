"""Grade the qa task: answers.md has the right integer for each of 10 questions."""
import pathlib
import re
import sys

EXPECTED = {1: 20, 2: 64, 3: 2000, 4: 3, 5: 60, 6: 64, 7: 7, 8: 900, 9: 256, 10: 16}

path = pathlib.Path("answers.md")
if not path.exists():
    print("FAIL: no answers.md"); sys.exit(1)
got = {int(m[1]): int(m[2].replace(",", "").replace("_", ""))
       for m in re.finditer(r"^\s*Q(\d+)\s*:\s*([\d,_]+)", path.read_text(), re.M)}
wrong = [q for q, v in EXPECTED.items() if got.get(q) != v]
print("PASS" if not wrong else f"FAIL: wrong or missing {wrong} (got {got})")
sys.exit(0 if not wrong else 1)
