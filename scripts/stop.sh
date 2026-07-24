#!/bin/sh
# Stop the daemon. The menu bar's "Quit Claude Maxx" does the same thing; this
# is the version you can run when the menu isn't reachable.
#
# Leaves everything else in place — hooks, the slash command, logins, stats.
# The daemon starts again on the next `/claude-maxx`, the next Claude Code
# session if "Start with Claude Code" is on, or ./scripts/restart.sh.
# To remove it entirely instead, use ./scripts/uninstall.sh.
. "$(dirname "$0")/lib.sh"

if pkill -f '\.build/(debug|release)/ClaudeMaxx' 2>/dev/null; then
    # SIGTERM is caught (see main.swift), so it closes any open content
    # episode and records it rather than vanishing mid-window.
    echo "stopped"
else
    echo "not running"
fi
