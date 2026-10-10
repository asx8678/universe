"""Grade task 1: index.md exists and names every module with its functions."""
import pathlib
import sys

idx = pathlib.Path("index.md")
if not idx.exists():
    print("FAIL: no index.md"); sys.exit(1)
text = idx.read_text()
missing = [i for i in range(1, 21) if f"mod_{i}" not in text or f"transform_{i}" not in text]
print("PASS" if not missing else f"FAIL: missing or incomplete {missing}")
sys.exit(0 if not missing else 1)
