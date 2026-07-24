#!/bin/bash
# Claude Maxx health check. Read-only — it diagnoses, never fixes, so it is
# always safe to run.
#
# Written to be read by an agent as much as a human: one `STATUS  check  detail`
# line per check, a FIX line naming the exact command whenever something is
# wrong, and an exit code that says whether anything is actually broken.
#
#   exit 0  everything required is working (WARNs may still be present)
#   exit 1  at least one FAIL — the daemon will not work correctly as-is
#
# WARN means degraded but functional; FAIL means broken. Nothing here depends
# on the daemon being reachable, so it also works as a pre-install check.
set -uo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
claude_dir="${CM_CLAUDE_DIR:-$HOME/.claude}"
settings="$claude_dir/settings.json"
cmd_file="$claude_dir/commands/claude-maxx.md"
url="http://127.0.0.1:8765"
failed=0

pass() { printf 'PASS  %-22s %s\n' "$1" "${2-}"; }
warn() { printf 'WARN  %-22s %s\n' "$1" "${2-}"; }
fail() { printf 'FAIL  %-22s %s\n' "$1" "${2-}"; failed=1; }
fix()  { printf '      ↳ fix: %s\n' "$1"; }

echo "Claude Maxx doctor — $repo"
# Source identity beside the running daemon's own reported version (below):
# together they say what the clone is at *and* what is actually running, which
# is the pair you need in a bug report from someone else's machine.
src_desc=$(git -C "$repo" describe --tags --always --dirty 2>/dev/null || echo "not a git clone")
echo "source: $src_desc"
echo

# ---- toolchain -------------------------------------------------------------

if [ "$(uname -s)" = "Darwin" ]; then
  pass "platform" "macOS $(sw_vers -productVersion 2>/dev/null)"
else
  fail "platform" "$(uname -s) — this is a macOS menu bar app (AppKit/WebKit)"
fi

if command -v swift >/dev/null 2>&1; then
  pass "swift" "$(swift --version 2>/dev/null | head -1)"
else
  fail "swift" "not found"
  fix "install Xcode or the Command Line Tools: xcode-select --install"
fi

if command -v python3 >/dev/null 2>&1; then
  pass "python3" "$(command -v python3)"
else
  fail "python3" "not found — install.sh needs it to edit settings.json safely"
fi

# The shipped hooks read session_id with jq, which macOS does NOT include.
# Without it the daemon still works: sid arrives empty and sessions are counted
# anonymously, which is correct for concurrency — you just lose per-session
# identity, so the watchdog can't expire one stuck session individually.
if command -v jq >/dev/null 2>&1; then
  pass "jq" "$(command -v jq)"
else
  warn "jq" "not installed — sessions are counted anonymously (still correct)"
  fix "optional: brew install jq   (for per-session tracking + watchdog expiry)"
fi

# ---- build -----------------------------------------------------------------

bin="$repo/.build/release/ClaudeMaxx"
[ -x "$bin" ] || bin="$repo/.build/debug/ClaudeMaxx"

if [ -x "$bin" ]; then
  pass "binary" "$bin"

  # The trap that looks exactly like a broken feature: sources edited after the
  # binary was built means the running daemon is old code, and every symptom is
  # a lie. Cheap to check, so always check.
  newest_src=$(find "$repo/Sources" -name '*.swift' -newer "$bin" -print -quit 2>/dev/null)
  if [ -n "$newest_src" ]; then
    fail "binary freshness" "sources are newer than the binary — it is stale"
    fix "swift build -c release && $repo/scripts/restart.sh"
  else
    pass "binary freshness" "newer than all sources"
  fi
else
  fail "binary" "not built"
  fix "swift build -c release   (or run ./scripts/install.sh)"
fi

# ---- daemon ----------------------------------------------------------------

running=$(pgrep -f '\.build/(debug|release)/ClaudeMaxx' | head -1)
if [ -n "$running" ]; then
  pass "daemon process" "pid $running"
  # `ps -o comm=` reports the path as *invoked*, which is relative when the
  # daemon was started with ./.build/… — resolve the real executable instead,
  # or a perfectly correct daemon gets reported as foreign. Note this lands on
  # the arch-specific directory (.build/arm64-apple-macosx/release) that
  # .build/release symlinks to, so match on the repo prefix, not the exact path.
  running_bin=$(lsof -a -p "$running" -d txt -Fn 2>/dev/null | sed -n '2s/^n//p')
  [ -n "$running_bin" ] || running_bin=$(ps -o comm= -p "$running" 2>/dev/null)
  case "$running_bin" in
    "$repo"*) pass "daemon origin" "this clone" ;;
    /*) warn "daemon origin" "running from $running_bin, not this clone"
        fix "$repo/scripts/restart.sh" ;;
    *)  warn "daemon origin" "could not resolve the running binary's path" ;;
  esac
else
  warn "daemon process" "not running"
  fix "it starts on the next Claude Code session, or now: $repo/scripts/restart.sh"
fi

status=$(curl -sG --max-time 2 --data-urlencode "arg=status" "$url/cmd" 2>/dev/null)
if [ -n "$status" ]; then
  pass "daemon responding" "$status"
  case "$status" in
    *"mode=off"*) warn "mode" "off — nothing will appear during prompts"
                  fix "/claude-maxx ask   (or: auto)" ;;
  esac
else
  if [ -n "$running" ]; then
    fail "daemon responding" "process is up but port 8765 is silent"
    fix "check for another process on 8765: lsof -nP -iTCP:8765"
  else
    warn "daemon responding" "nothing listening on 8765 (daemon is not running)"
  fi
fi

# ---- Claude Code wiring ----------------------------------------------------

if [ -f "$cmd_file" ]; then
  if grep -q "$repo" "$cmd_file" 2>/dev/null; then
    pass "/claude-maxx command" "$cmd_file"
  else
    fail "/claude-maxx command" "installed, but points at a different clone"
    fix "./scripts/install.sh   (rewrites it to point here)"
  fi
else
  fail "/claude-maxx command" "not installed"
  fix "./scripts/install.sh"
fi

if [ -f "$settings" ]; then
  # Four HTTP hooks carry the actual feature: UserPromptSubmit, Stop,
  # SessionEnd, Notification. All four are required — a missing Stop is what
  # leaves the window up after a prompt finishes.
  hook_count=$(grep -c '127.0.0.1:8765' "$settings" 2>/dev/null || echo 0)
  if [ "$hook_count" -ge 4 ]; then
    pass "hooks registered" "$hook_count/4 in $settings"
  elif [ "$hook_count" -gt 0 ]; then
    fail "hooks registered" "only $hook_count of 4 required hooks present"
    fix "./scripts/install.sh"
  else
    fail "hooks registered" "none found in $settings"
    fix "./scripts/install.sh"
  fi

  # Hooks are written into settings.json at install time, so a clone that has
  # been pulled since does not get hook changes until install.sh re-runs. That
  # is invisible otherwise: everything works, just without the newer behavior.
  if grep -q 'suppress=1' "$settings" 2>/dev/null; then
    pass "hooks up to date" "command turns will not open a window"
  else
    warn "hooks up to date" "older UserPromptSubmit hook — /claude-maxx turns can flash content"
    fix "./scripts/install.sh   (rewrites the hooks, then restart Claude Code)"
  fi

  # The fifth is deliberately optional: it is the menu bar's "Start with
  # Claude Code" toggle, so its absence is a choice, not a broken install.
  if grep -q 'claude-maxx-ensure.sh' "$settings" 2>/dev/null; then
    pass "autostart hook" "on — daemon starts with Claude Code"
  else
    pass "autostart hook" "off — start it yourself, or /claude-maxx starts it on demand"
  fi
else
  fail "hooks registered" "$settings does not exist"
  fix "./scripts/install.sh"
fi

echo
if [ "$failed" -eq 0 ]; then
  echo "All required checks passed."
  # Hooks are read once at session start, so a fresh install is invisible to
  # the session that ran it — the single most common "I installed it and
  # nothing happens".
  echo "If you just installed: restart Claude Code so it picks up the hooks."
else
  echo "Something is broken — see the FAIL lines above."
fi
exit "$failed"
