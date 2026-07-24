#!/bin/sh
# Stop whatever Claude Maxx is running and start this clone's binary.
#
# The daemon is long-lived and a rebuild does not touch the running process, so
# after editing Sources/ every symptom you observe belongs to the old code — a
# fix that "didn't work" is usually a stale daemon.
#
# Does NOT build. Chain it: swift build -c release && ./scripts/restart.sh
. "$(dirname "$0")/lib.sh"

bin=$(cm_bin "$(cm_repo "$0")")
[ -n "$bin" ] || { echo "nothing built — run: swift build -c release" >&2; exit 1; }

pkill -f '\.build/(debug|release)/ClaudeMaxx' 2>/dev/null && echo "stopped the running daemon"
# Wait for the old process to release port 8765; starting immediately leaves the
# new one unable to bind, sitting there useless with its menu bar icon up.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -z "$(cm_send status)" ] && break
    sleep 0.3
done

cm_launch "$bin"
echo "started $bin"
cm_await status || { echo "started, but not responding on 8765 — see $(cm_log_path)" >&2; exit 1; }
