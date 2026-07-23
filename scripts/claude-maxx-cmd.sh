#!/bin/sh
# /claude-maxx transport: forwards the subcommand to the daemon's /cmd
# endpoint, auto-starting the daemon from the local build if it's not up.
# Interim until M3's install.sh provides a stable installed binary path.
url="http://127.0.0.1:8765/cmd"
out=$(curl -sG --max-time 1 --data-urlencode "arg=$*" "$url") && { printf '%s\n' "$out"; exit 0; }

bin="$HOME/Documents/Code/claude-maxxing/.build/debug/ClaudeMaxx"
[ -x "$bin" ] || { echo "daemon not running and no binary at $bin — run swift build first"; exit 0; }
nohup "$bin" >/dev/null 2>&1 &
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.3
  out=$(curl -sG --max-time 1 --data-urlencode "arg=$*" "$url") && { printf 'daemon started\n%s\n' "$out"; exit 0; }
done
echo "daemon failed to start — check it manually"
