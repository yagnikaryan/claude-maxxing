#!/bin/bash
# Exact inverse of install.sh: stops the daemon, removes the slash command,
# and strips this project's hook entries from settings.json.
#
# Deliberately leaves your data alone — stats and settings are yours, and a
# reinstall should find them where it left them. Both paths are printed at the
# end so removing them by hand is one copy-paste.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
claude_dir="${CM_CLAUDE_DIR:-$HOME/.claude}"
settings="$claude_dir/settings.json"
cmd_dst="$claude_dir/commands/claude-maxx.md"

say() { printf '  %s\n' "$*"; }

echo "Claude Maxx — uninstalling"

echo
echo "[1/3] Stopping the daemon…"
if pkill -f '\.build/(debug|release)/ClaudeMaxx' 2>/dev/null; then
  say "stopped"
else
  say "not running"
fi

echo
echo "[2/3] Removing the /claude-maxx command…"
if [ -f "$cmd_dst" ]; then
  rm "$cmd_dst"
  say "removed $cmd_dst"
else
  say "not installed"
fi

echo
echo "[3/3] Removing hooks from ${settings}…"
if [ -f "$settings" ] && command -v python3 >/dev/null 2>&1; then
  CM_SETTINGS="$settings" python3 <<'PY'
import json, os, shutil, sys

settings_path = os.environ["CM_SETTINGS"]
# Mirrors install.sh: SessionStart runs a script by path rather than talking
# to the daemon over HTTP, so the URL alone would miss it.
MARKERS = ("127.0.0.1:8765", "claude-maxx-ensure.sh")

def ours_hook(command):
    return any(m in command for m in MARKERS)

with open(settings_path) as f:
    try:
        settings = json.load(f)
    except json.JSONDecodeError as e:
        sys.exit(f"  error: {settings_path} is not valid JSON ({e}) — leaving it untouched.")

hooks = settings.get("hooks", {})
removed = 0
for event in list(hooks):
    groups = []
    for group in hooks[event]:
        survivors = [h for h in group.get("hooks", []) if not ours_hook(h.get("command", ""))]
        removed += len(group.get("hooks", [])) - len(survivors)
        if survivors:
            groups.append(dict(group, hooks=survivors))
    # Drop the event entirely if we were the only thing hooking it.
    if groups:
        hooks[event] = groups
    else:
        del hooks[event]
if not hooks:
    settings.pop("hooks", None)

if removed:
    shutil.copy2(settings_path, settings_path + ".claude-maxx.bak")
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print(f"  removed {removed} hook entr{'y' if removed == 1 else 'ies'} "
          f"(backup at {settings_path}.claude-maxx.bak)")
else:
    print("  no Claude Maxx hooks found")
PY
else
  say "nothing to do"
fi

cat <<EOF

Done. Your data was left in place:

  stats     ~/Library/Application Support/ClaudeMaxx/stats.jsonl
  logins    ~/Library/HTTPStorages/ClaudeMaxx.binarycookies, ~/Library/WebKit/ClaudeMaxx
  settings  defaults delete ClaudeMaxx
  logs      ~/Library/Logs/ClaudeMaxx.log

Nothing else is left running or registered — there is no login item and no
launch agent. Delete $repo whenever you like.
EOF
