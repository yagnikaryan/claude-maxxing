#!/bin/sh
# /claude-maxx transport: forwards the subcommand to the daemon, starting it
# first if nothing is listening.
#
# Everything resolves relative to this script, so the repo works wherever it is
# cloned. Only the slash command file needs an absolute path (a command file
# cannot locate the repo on its own) and install.sh writes that one.
. "$(dirname "$0")/lib.sh"

out=$(cm_send "$*") && [ -n "$out" ] && { printf '%s\n' "$out"; exit 0; }

bin=$(cm_bin "$(cm_repo "$0")")
[ -n "$bin" ] || {
    echo "daemon not running, and nothing built — run: swift build -c release"
    exit 0
}

cm_launch "$bin"
out=$(cm_await "$*") && { printf 'daemon started\n%s\n' "$out"; exit 0; }
echo "daemon failed to start — see $(cm_log_path)"
