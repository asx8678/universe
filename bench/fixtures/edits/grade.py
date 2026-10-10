import importlib.util, pathlib, sys
ok = True
for p in sorted(pathlib.Path("lib").glob("f*.py")):
    src = p.read_text()
    if "old_api" in src:
        print(f"FAIL {p}: old_api still present"); ok = False
    spec = importlib.util.spec_from_file_location(p.stem, p)
    m = importlib.util.module_from_spec(spec)
    try: spec.loader.exec_module(m)
    except Exception as e: print(f"FAIL {p}: {e}"); ok = False; continue
    if not hasattr(m, "new_api"): print(f"FAIL {p}: no new_api"); ok = False
print("PASS" if ok else "FAIL"); sys.exit(0 if ok else 1)
