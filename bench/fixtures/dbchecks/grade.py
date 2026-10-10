import pathlib, re
r = pathlib.Path("report.md")
if not r.exists(): print("FAIL: no report.md"); raise SystemExit(1)
t = r.read_text().lower()
checks = len(re.findall(r"(pass|fail)", t))
print("PASS" if checks >= 20 else f"FAIL: only {checks} pass/fail markers")
