"""Grade task 2: every old_api renamed, every module imports, new_api works."""
import importlib.util
import pathlib
import sys

ok = True
for p in sorted(pathlib.Path("lib").glob("f*.py")):
    n = int(p.stem[1:])
    src = p.read_text()
    if "old_api" in src:
        print(f"FAIL {p}: old_api still present"); ok = False; continue
    spec = importlib.util.spec_from_file_location(p.stem, p)
    m = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(m)
        assert m.new_api(2) == 2 * n, "new_api value"
        assert getattr(m, f"use_{n}")(2) == 2 * n + n, "call site"
    except Exception as e:
        print(f"FAIL {p}: {e}"); ok = False
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
