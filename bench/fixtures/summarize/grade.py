import pathlib, re
idx = pathlib.Path("index.md")
if not idx.exists(): print("FAIL: no index.md"); raise SystemExit(1)
text = idx.read_text()
missing = [i for i in range(1, 21) if f"mod_{i}" not in text]
print("PASS" if not missing else f"FAIL: missing {missing}")
