#!/bin/sh
# Toggle the SessionStart hook that starts the daemon with Claude Code.
#
#   claude-maxx-hook.sh status    -> prints "enabled" or "disabled" (exit 0)
#   claude-maxx-hook.sh enable
#   claude-maxx-hook.sh disable
#
# Backs the menu bar's "Start with Claude Code" item, and is what install.sh
# would use to add this one hook on its own. Kept as a script rather than
# native code so every edit to settings.json goes through the same
# order-preserving JSON round-trip — rewriting that file from Swift would
# reorder the user's keys, since Foundation dictionaries are unordered.
set -eu

action="${1:-status}"
repo=$(cd "$(dirname "$0")/.." && pwd)

CM_SETTINGS="${CM_CLAUDE_DIR:-$HOME/.claude}/settings.json" \
CM_ENSURE="$repo/scripts/claude-maxx-ensure.sh" \
CM_ACTION="$action" \
python3 <<'PY'
import json, os, shutil, sys

path = os.environ["CM_SETTINGS"]
ensure = os.environ["CM_ENSURE"]
action = os.environ["CM_ACTION"]
MARKER = "claude-maxx-ensure.sh"
COMMAND = f"{ensure} > /dev/null 2>&1 || true"

if os.path.exists(path):
    try:
        with open(path) as f:
            settings = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        # Never leave a user's settings worse than we found them.
        sys.exit(f"cannot read {path}: {e}")
else:
    settings = {}

groups = settings.get("hooks", {}).get("SessionStart", [])
present = any(MARKER in h.get("command", "")
              for g in groups for h in g.get("hooks", []))

if action == "status":
    print("enabled" if present else "disabled")
    raise SystemExit(0)

if action not in ("enable", "disable"):
    sys.exit(f"usage: claude-maxx-hook.sh [status|enable|disable]")

if (action == "enable") == present:
    print("enabled" if present else "disabled")   # already in the requested state
    raise SystemExit(0)

hooks = settings.setdefault("hooks", {})
# Strip any existing entry of ours first, so enable is also a repair for a
# stale path (a moved clone) rather than a second copy.
kept = []
for group in hooks.get("SessionStart", []):
    survivors = [h for h in group.get("hooks", []) if MARKER not in h.get("command", "")]
    if survivors:
        kept.append(dict(group, hooks=survivors))

if action == "enable":
    kept.append({"hooks": [{"type": "command", "command": COMMAND}]})

if kept:
    hooks["SessionStart"] = kept
else:
    hooks.pop("SessionStart", None)
if not hooks:
    settings.pop("hooks", None)

if os.path.exists(path):
    shutil.copy2(path, path + ".claude-maxx.bak")
else:
    os.makedirs(os.path.dirname(path), exist_ok=True)

tmp = path + ".claude-maxx.tmp"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(tmp, path)   # atomic: a crash mid-write can't truncate settings.json

print("enabled" if action == "enable" else "disabled")
PY
