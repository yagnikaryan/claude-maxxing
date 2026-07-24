#!/bin/sh
# Start the daemon if it isn't already running, then exit immediately.
#
# Wired to Claude Code's SessionStart hook so the daemon's lifetime matches the
# only thing it reacts to. That beats a login item: with no packaged .app,
# "Launch at Login" would register the path of whatever binary was running and
# go stale on the next rebuild.
#
# Runs on every session start, so it must be cheap and must never block — the
# probe is a 1s loopback request and the launch is detached. Failure is silent
# by design: no hook should be able to stop a session from opening.
. "$(dirname "$0")/lib.sh"

[ -n "$(cm_send status)" ] && exit 0

repo=$(cm_repo "$0")
bin=$(cm_bin "$repo")
[ -n "$bin" ] || exit 0   # never built — not this hook's job to say so
cm_launch "$bin" "$repo"
exit 0
