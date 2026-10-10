#!/usr/bin/env bash
# PreToolUse hook for Bash. When this project has a running Universe, block
# Bash (exit 2: the message goes to the model) and point at the tick tool.
# Without a reachable daemon it allows everything, so the plugin is harmless
# elsewhere. UNIVERSE_ALLOW_BASH=1 turns the redirect off.
set -u

[ "${UNIVERSE_ALLOW_BASH:-}" = "1" ] && exit 0

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
port_file="$dir/.universe/port"
token_file="$dir/.universe/token"
[ -f "$port_file" ] && [ -f "$token_file" ] || exit 0

port=$(cat "$port_file")
token=$(cat "$token_file")

# Recording the redirect doubles as the liveness check.
code=$(curl -s -m 1 -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $token" -H 'content-type: application/json' \
  --data-binary @- "http://127.0.0.1:$port/hooks/redirect")

[ "$code" = "200" ] || exit 0

cat >&2 <<'MSG'
Bash is off in this project: Universe runs all execution. Send the command as a
run directive through mcp__universe__tick instead, for example
{"directives":[{"op":"run","label":"tests","lang":"bash","code":"mix test"}]}.
Batch independent commands into one tick. See the universe skill.
MSG
exit 2
