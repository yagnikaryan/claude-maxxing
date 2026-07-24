#!/bin/bash
# Stop whatever Claude Maxx is running and start this clone's binary.
#
# Exists because the daemon is long-lived and a rebuild does not touch the
# running process: after editing Sources/, the old binary keeps running and
# every symptom you observe belongs to the old code. That failure is
# indistinguishable from a broken feature — a channel that "still shows a blank
# page" after the fix landed is the canonical case.
#
# Does NOT build. Chain it when you have changed code:
#   swift build -c release && ./scripts/restart.sh
set -uo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
bin="$repo/.build/release/ClaudeMaxx"
[ -x "$bin" ] || bin="$repo/.build/debug/ClaudeMaxx"
[ -x "$bin" ] || {
  echo "no binary in $repo/.build — run: swift build -c release" >&2
  exit 1
}

log="$HOME/Library/Logs/ClaudeMaxx.log"
mkdir -p "$(dirname "$log")"

pkill -f '\.build/(debug|release)/ClaudeMaxx' 2>/dev/null && echo "stopped the running daemon"
# Give the old process time to release port 8765 — starting immediately makes
# the new one fail its bind and sit there useless with the menu bar icon up.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -sG --max-time 1 --data-urlencode "arg=status" "http://127.0.0.1:8765/cmd" >/dev/null 2>&1 || break
  sleep 0.3
done

nohup "$bin" >>"$log" 2>&1 &
echo "started $bin"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.3
  out=$(curl -sG --max-time 1 --data-urlencode "arg=status" "http://127.0.0.1:8765/cmd" 2>/dev/null)
  [ -n "$out" ] && { echo "$out"; exit 0; }
done

echo "started, but not responding on 8765 yet — see $log" >&2
exit 1
