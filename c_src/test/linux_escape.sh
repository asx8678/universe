#!/bin/sh
# Linux escape matrix for Universe.Isolation.Bubblewrap, run as a normal
# user in a Linux container:
#   sh c_src/test/linux_escape.sh <universe_run> <args-file> <args-file-with-net>
# The args files hold the adapter's bwrap arguments (one per line) for
# root=/home/u/proj, run_dir=/home/u/proj/.universe/runs/1, lease out/ (and
# lease "." in the third file, with network). Mirrors test/isolation/escape_test.exs.
set -u
LAUNCHER=$1; ARGS=$2; ARGS_NET=$3
P=/home/u/proj; fails=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fails=$((fails+1)); }
box()  { f=$1; shift; set -- $(cat "$f") -- "$@"; IFS=' '; bwrap "$@"; }
in_box() { box "$ARGS" sh -c "$1" >/dev/null 2>&1; }

mkdir -p $P/out $P/src $P/.universe/runs/1 $P/.universe/secrets
echo original > $P/src/victim.txt; echo tok > $P/.universe/token; echo s=1 > $P/.universe/secrets/pg.env
echo private > /home/u/secret.txt

in_box "echo hi > $P/out/a.txt" && [ -f $P/out/a.txt ] && ok "write inside the lease" || bad "write inside the lease"
in_box "echo x > $P/src/victim.txt"; [ "$(cat $P/src/victim.txt)" = original ] && ok "write outside the lease fails" || bad "write outside the lease fails"
ln -sf $P/src/victim.txt $P/out/link; in_box "echo x > $P/out/link"; [ "$(cat $P/src/victim.txt)" = original ] && ok "a symlink in the lease doesn't lead out" || bad "symlink escape"
in_box "echo x > $P/out/../src/victim.txt"; [ "$(cat $P/src/victim.txt)" = original ] && ok ".. traversal fails" || bad ".. traversal"
in_box "ln $P/src/victim.txt $P/out/hard && echo x > $P/out/hard"; [ "$(cat $P/src/victim.txt)" = original ] && ok "hard link out of the lease fails" || bad "hard link"
in_box "echo x > /tmp/escaped"; [ ! -e /tmp/escaped ] && ok "/tmp writes stay inside the box" || bad "/tmp write escaped"
in_box "cat /home/u/secret.txt" && bad "\$HOME is unreadable" || ok "\$HOME is unreadable"
in_box "cat $P/.universe/token" && bad "token unreadable" || ok "the token is unreadable"
in_box "cat $P/.universe/secrets/pg.env" && bad "secrets unreadable" || ok "secrets are unreadable"
in_box "echo x > $P/.universe/runs/1/mine" && [ -f $P/.universe/runs/1/mine ] && ok "its own run dir is writable" || bad "run dir write"
box "$ARGS_NET" sh -c "echo x > $P/.universe/token" >/dev/null 2>&1; [ "$(cat $P/.universe/token)" = tok ] && ok "a lease on . still can't write .universe" || bad "lease on . wrote .universe"
in_box "python3 -c 'import socket; socket.create_connection((\"1.1.1.1\", 53), 2)'" && bad "no network" || ok "snippets have no network"
in_box "cat $P/src/victim.txt" && ok "the project is readable" || bad "project readable"

# The SDK socket works from inside.
python3 - <<PY &
import socket, os
p = "$P/.universe/sdk.sock"
try: os.unlink(p)
except OSError: pass
s = socket.socket(socket.AF_UNIX); s.bind(p); s.listen(1)
c, _ = s.accept(); c.sendall(b"pong"); c.close()
PY
sleep 0.5
out=$(box "$ARGS" python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.connect('$P/.universe/sdk.sock'); print(s.recv(4).decode())" 2>&1)
[ "$out" = pong ] && ok "the SDK socket is reachable" || bad "SDK socket ($out)"

# Killing the launcher's group kills everything in the box, setsid included.
rm -f $P/out/pid
python3 - "$LAUNCHER" "$ARGS" "$P" <<'PY'
import struct, subprocess, sys, time, os
launcher, argsf, P = sys.argv[1:]
box = ["bwrap"] + open(argsf).read().split() + ["--"]
p = subprocess.Popen([launcher, "--grace", "300", "--"] + box +
    ["sh", "-c", f"setsid sleep 300 & echo $! > {P}/out/pid; sleep 300"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
for _ in range(100):
    if os.path.exists(f"{P}/out/pid") and open(f"{P}/out/pid").read().strip(): break
    time.sleep(0.05)
# Find the setsid'd sleep in the host's view.
pids = subprocess.run(["pgrep", "-f", "sleep 300"], capture_output=True, text=True).stdout.split()
pgid_ok = all(os.getpgid(int(x)) == p.pid or True for x in pids)
groups = {x: os.getpgid(int(x)) for x in pids}
p.stdin.write(struct.pack(">I", 1) + b"K"); p.stdin.flush(); p.wait(timeout=10)
time.sleep(0.5)
left = subprocess.run(["pgrep", "-f", "sleep 300"], capture_output=True, text=True).stdout.split()
print("ok   kill takes down the box, setsid escapees included" if pids and not left
      else f"FAIL kill: before={pids} after={left}")
non_group = [x for x, g in groups.items() if g != p.pid]
print(f"info process groups in the box: {groups} (launcher child group {p.pid}); outside the group: {non_group}")
PY

echo; [ $fails -eq 0 ] && echo "PASS (shell checks)" || echo "FAIL: $fails"
