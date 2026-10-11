#!/bin/sh
# Everything Linux-side in one go, inside a fresh Linux container (Alpine):
#   container run --rm -v "$PWD":/src alpine:3.20 sh /src/c_src/test/linux_all.sh
# Builds the launcher with gcc and clang, runs its harness with each, then
# runs the bubblewrap escape matrix as a normal user. Prints a summary and
# exits non-zero if anything failed.
set -u
apk add --no-cache gcc clang musl-dev python3 bubblewrap shadow >/dev/null || exit 2
fails=0
cd /src

for cc in gcc clang; do
  out=/tmp/universe_run_$cc
  if $cc -O2 -Wall -Wextra -Werror -std=c99 -D_DEFAULT_SOURCE -o $out c_src/universe_run.c; then
    echo "ok   build with $cc"
    if python3 c_src/test/launcher_test.py $out; then
      echo "ok   launcher harness ($cc)"
    else
      echo "FAIL launcher harness ($cc)"; fails=$((fails+1))
    fi
  else
    echo "FAIL build with $cc"; fails=$((fails+1))
  fi
done

# The escape matrix runs as a normal user, as Universe would.
useradd -m u 2>/dev/null || adduser -D u
cp /tmp/universe_run_gcc /home/u/universe_run
cp c_src/test/bwrap_args.txt c_src/test/bwrap_args_net.txt c_src/test/linux_escape.sh /home/u/
chown -R u /home/u
if su u -c "cd /home/u && sh linux_escape.sh /home/u/universe_run /home/u/bwrap_args.txt /home/u/bwrap_args_net.txt"; then
  echo "ok   bubblewrap escape matrix"
else
  echo "FAIL bubblewrap escape matrix"; fails=$((fails+1))
fi

echo "linux_all: $fails failed"
exit $fails
