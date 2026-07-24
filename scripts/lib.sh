# shellcheck shell=sh
# Shared helpers for the three launchers (ensure / cmd / restart). Sourced,
# never executed.
#
# Exists so "how the daemon is started" is defined once. It was three copies,
# which is the kind of drift that leaves one entry point on a stale flag while
# the others are fixed.

CM_URL="http://127.0.0.1:8765"

# Repo root, given the caller's $0.
cm_repo() { (cd "$(dirname "$1")/.." && pwd); }

# Preferred binary, or empty if the project has never been built. Release is
# what install.sh produces; debug is the dev fallback.
cm_bin() {
    _b="$1/.build/release/ClaudeMaxx"
    [ -x "$_b" ] || _b="$1/.build/debug/ClaudeMaxx"
    [ -x "$_b" ] && printf '%s' "$_b"
}

cm_log_path() { printf '%s' "$HOME/Library/Logs/ClaudeMaxx.log"; }

# One /cmd round-trip. Empty output means nothing is listening.
cm_send() { curl -sG --max-time 1 --data-urlencode "arg=$1" "$CM_URL/cmd" 2>/dev/null; }

# Detached start. The daemon calls setsid() itself, so it leaves this process
# group on its own — see main.swift; do not "fix" this by adding job control.
cm_launch() {
    _log=$(cm_log_path)
    mkdir -p "$(dirname "$_log")" 2>/dev/null
    nohup "$1" >>"$_log" 2>&1 &
}

# Poll until the daemon answers, echoing its reply. Non-zero if it never does.
cm_await() {
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.3
        _out=$(cm_send "${1:-status}")
        [ -n "$_out" ] && { printf '%s\n' "$_out"; return 0; }
    done
    return 1
}
