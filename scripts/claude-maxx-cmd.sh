#!/bin/sh
# /claude-maxx transport: forwards the subcommand to the daemon's /cmd
# endpoint, auto-starting the daemon if nothing is listening.
#
# The binary is located relative to this script rather than an absolute path,
# so the repo works wherever it is cloned. Only the slash command needs an
# absolute path (a command file can't locate the repo on its own) and
# install.sh writes that one.
url="http://127.0.0.1:8765/cmd"
out=$(curl -sG --max-time 1 --data-urlencode "arg=$*" "$url") && { printf '%s\n' "$out"; exit 0; }

repo=$(cd "$(dirname "$0")/.." && pwd)
# Prefer release (what install.sh builds); fall back to a dev debug build.
bin="$repo/.build/release/ClaudeMaxx"
[ -x "$bin" ] || bin="$repo/.build/debug/ClaudeMaxx"
[ -x "$bin" ] || {
  echo "daemon not running, and no binary in $repo/.build — run: swift build -c release"
  exit 0
}

log="$HOME/Library/Logs/ClaudeMaxx.log"
mkdir -p "$(dirname "$log")"
nohup "$bin" >>"$log" 2>&1 &
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.3
  out=$(curl -sG --max-time 1 --data-urlencode "arg=$*" "$url") && { printf 'daemon started\n%s\n' "$out"; exit 0; }
done
echo "daemon failed to start — see $log"
