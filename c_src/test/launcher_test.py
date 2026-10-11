#!/usr/bin/env python3
"""Portable launcher checks (run on macOS and Linux):

    python3 c_src/test/launcher_test.py path/to/universe_run

Speaks the port protocol ({packet,4}: P pid, O/E output, X code signal; K
kills) and checks: exit codes and signals, output framing, that K kills the
whole process group, that closing stdin (the BEAM dying) does too, the grace
period before SIGKILL, and RLIMIT_FSIZE.
"""
import os, struct, subprocess, sys, tempfile, time

LAUNCHER = os.path.abspath(sys.argv[1])
failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(name)


def start(cmd, grace=300, fsize=None):
    args = [LAUNCHER, "--grace", str(grace)] + (["--fsize", str(fsize)] if fsize else []) + ["--"] + cmd
    return subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def packets(p, until_exit=True, timeout=10):
    out, end = [], time.time() + timeout
    while time.time() < end:
        head = p.stdout.read(4)
        if len(head) < 4:
            break
        (n,) = struct.unpack(">I", head)
        body = p.stdout.read(n)
        out.append(body)
        if until_exit and body[:1] == b"X":
            break
    return out


def exit_of(pk):
    x = [b for b in pk if b[:1] == b"X"]
    return struct.unpack(">II", x[-1][1:9]) if x else None


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # A zombie still answers kill(0); check its state where we can.
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().split(")")[-1].split()[0] != "Z"
    except OSError:
        out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout
        return bool(out.strip()) and not out.strip().startswith("Z")


def wait_gone(pids, timeout=5):
    end = time.time() + timeout
    while time.time() < end and any(alive(x) for x in pids):
        time.sleep(0.05)
    return [x for x in pids if alive(x)]


# 1. exit code and output framing
p = start(["sh", "-c", "echo hello; echo oops >&2; exit 3"])
pk = packets(p)
check("P packet first carries the child pid", pk and pk[0][:1] == b"P" and len(pk[0]) == 5)
check("stdout arrives as O", b"".join(b[1:] for b in pk if b[:1] == b"O") == b"hello\n")
check("stderr arrives as E", b"".join(b[1:] for b in pk if b[:1] == b"E") == b"oops\n")
check("exit code 3, no signal", exit_of(pk) == (3, 0), str(exit_of(pk)))
p.wait()

# 2. death by signal is reported
p = start(["sh", "-c", "kill -TERM $$"])
x = exit_of(packets(p))
check("signal reported in X", x is not None and x[1] == 15, str(x))
p.wait()

# Children that record their pids, so we can check the whole group dies.
tmp = tempfile.mkdtemp()
tree = f"sleep 300 & echo $! > {tmp}/a; (sleep 300 & echo $! > {tmp}/b; wait) & wait"


def tree_pids():
    end = time.time() + 5
    while time.time() < end:
        try:
            return [int(open(f"{tmp}/{n}").read()) for n in "ab"]
        except (OSError, ValueError):
            time.sleep(0.05)
    return []


# 3. K kills the whole group, grandchildren included
for n in "ab":
    try: os.remove(f"{tmp}/{n}")
    except OSError: pass
p = start(["sh", "-c", tree])
pids = tree_pids()
check("tree started", len(pids) == 2, str(pids))
p.stdin.write(struct.pack(">I", 1) + b"K"); p.stdin.flush()
pk = packets(p)
check("K: exit reported with a signal", exit_of(pk) is not None and exit_of(pk)[1] != 0, str(exit_of(pk)))
check("K: grandchildren are gone", wait_gone(pids) == [], str(wait_gone(pids)))
p.wait()

# 4. closing stdin (the BEAM died) kills the group too
for n in "ab":
    try: os.remove(f"{tmp}/{n}")
    except OSError: pass
p = start(["sh", "-c", tree])
pids = tree_pids()
p.stdin.close()
p.wait(timeout=10)
check("EOF: launcher exits", p.returncode is not None)
check("EOF: grandchildren are gone", wait_gone(pids) == [], str(wait_gone(pids)))

# 5. grace: a child that ignores SIGTERM gets SIGKILL after the grace period
p = start(["sh", "-c", "trap '' TERM; sleep 300 & wait; sleep 300"], grace=500)
time.sleep(0.3)
t0 = time.time()
p.stdin.write(struct.pack(">I", 1) + b"K"); p.stdin.flush()
pk = packets(p)
took = time.time() - t0
check("grace: SIGKILL follows after ~0.5 s", exit_of(pk) is not None and 0.4 <= took < 3, f"{took:.2f}s {exit_of(pk)}")
p.wait()

# 6. RLIMIT_FSIZE stops a runaway writer
out = os.path.join(tmp, "big")
p = start(["sh", "-c", f"head -c 200000 /dev/zero > {out}"], fsize=100000)
pk = packets(p)
size = os.path.getsize(out) if os.path.exists(out) else -1
check("fsize: file capped at the limit", 0 <= size <= 100000, f"size={size} exit={exit_of(pk)}")
p.wait()

print(f"\n{'PASS' if not failures else 'FAIL'}: {len(failures)} failing")
sys.exit(1 if failures else 0)
