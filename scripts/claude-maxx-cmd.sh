#!/bin/sh
# /claude-maxx transport: forwards the subcommand to the daemon, starting it
# first if nothing is listening.
#
# Everything resolves relative to this script, so the repo works wherever it is
# cloned. Only the slash command file needs an absolute path (a command file
# cannot locate the repo on its own) and install.sh writes that one.
. "$(dirname "$0")/lib.sh"

out=$(cm_send "$*") && [ -n "$out" ] && { printf '%s\n' "$out"; exit 0; }

# Nothing answered. Every other subcommand wants the daemon started first, but
# starting one in order to stop it is absurd — and worse, the `daemon started`
# line printed below would read as though quit had done the opposite of what it
# says. The requested state already holds, so say so and stop.
[ "$*" = "quit" ] && { echo "not running — nothing to stop"; exit 0; }

repo=$(cm_repo "$0")
bin=$(cm_bin "$repo")
[ -n "$bin" ] || {
    echo "daemon not running, and nothing built — run: swift build -c release"
    exit 0
}

cm_launch "$bin" "$repo"
out=$(cm_await "$*") && { printf 'daemon started\n%s\n' "$out"; exit 0; }
echo "daemon failed to start — see $(cm_log_path)"
