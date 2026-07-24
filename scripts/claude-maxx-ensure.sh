#!/bin/sh
# Start the daemon if it isn't already running, then exit immediately.
#
# Wired to Claude Code's SessionStart hook so the daemon is up the moment you
# open Claude, without a login item. That matters beyond convenience: with no
# packaged .app, "Launch at Login" registers the *path of the running binary*,
# which goes stale on a clean or release rebuild. Tying startup to Claude
# instead means the daemon's lifetime matches the only thing it reacts to, and
# there is nothing registered with the OS to go stale.
#
# Runs on every session start, so it must be cheap and must never block:
# the liveness probe is a 0.3s loopback request, and the daemon is launched
# detached with output redirected. A failure here is silent by design — no
# hook should be able to stop a session from opening.
[ -n "$(curl -sG --max-time 1 --data-urlencode "arg=status" "http://127.0.0.1:8765/cmd" 2>/dev/null)" ] && exit 0

repo=$(cd "$(dirname "$0")/.." && pwd)
bin="$repo/.build/release/ClaudeMaxx"
[ -x "$bin" ] || bin="$repo/.build/debug/ClaudeMaxx"
[ -x "$bin" ] || exit 0   # not built — nothing to start, and not this hook's job to say so

log="$HOME/Library/Logs/ClaudeMaxx.log"
mkdir -p "$(dirname "$log")" 2>/dev/null
nohup "$bin" >>"$log" 2>&1 &
exit 0
