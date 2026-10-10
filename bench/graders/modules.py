"""Grade the modules task: index.md has a line per file under lib/ naming one of its functions."""
import pathlib
import re
import sys

idx = pathlib.Path("index.md")
if not idx.exists():
    print("FAIL: no index.md"); sys.exit(1)
lines = idx.read_text().splitlines()
bad = []
for f in sorted(pathlib.Path("lib").rglob("*.ex")):
    rel = str(f)
    short = str(f.relative_to("lib"))
    hits = [l for l in lines if rel in l or short in l]
    funs = set(re.findall(r"^\s*def\s+([a-z_][a-zA-Z0-9_?!]*)", f.read_text(), re.M))
    if not hits or not any(fn in l for l in hits for fn in funs):
        bad.append(short)
print("PASS" if not bad else f"FAIL: {len(bad)} files missing or without a function: {bad[:6]}")
sys.exit(0 if not bad else 1)
