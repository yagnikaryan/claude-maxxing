#!/bin/sh
# Start the daemon if it isn't already running, and say what state it's in.
#
# The counterpart to stop.sh, and the answer to "nothing is running after a
# reboot". Idempotent — running it twice reports the daemon rather than
# starting a second one.
#
# There is no /claude-maxx start, because a command needs a daemon to receive
# it. The command wrapper covers that instead: any /claude-maxx invocation
# launches the daemon first if nothing answers, so `/claude-maxx status` both
# starts it and reports. This script is the same thing from a terminal.
. "$(dirname "$0")/lib.sh"

out=$(cm_send status)
[ -n "$out" ] && { echo "already running"; printf '%s\n' "$out"; exit 0; }

repo=$(cm_repo "$0")
bin=$(cm_bin "$repo")
[ -n "$bin" ] || { echo "nothing built — run: swift build -c release" >&2; exit 1; }

cm_launch "$bin" "$repo"
cm_await status || { echo "started, but not responding on 8765 — see $(cm_log_path)" >&2; exit 1; }
