#!/usr/bin/env bash
# SessionStart hook: print what already runs in this project's Universe
# (services, live workers, leases, handles). Stdout joins the session context.
set -u

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
port_file="$dir/.universe/port"
token_file="$dir/.universe/token"
[ -f "$port_file" ] && [ -f "$token_file" ] || exit 0

manifest=$(curl -s -m 2 -f -H "Authorization: Bearer $(cat "$token_file")" \
  "http://127.0.0.1:$(cat "$port_file")/hooks/manifest") || exit 0

cat <<MSG
Universe is running for this project. All execution goes through
mcp__universe__tick and mcp__universe__inspect (use the universe skill); Bash is redirected.
Build the helpers a task needs: services for what you use more than once, agents
for judgment work, given the services they need, steered while they work.

$manifest
MSG
