#!/bin/bash
# Claude Maxx installer: build, register the slash command, merge the hooks,
# start the daemon. Safe to re-run — every step is idempotent.
#
# Deliberately does not install anything outside the repo except two things
# under ~/.claude: the command file, and this project's four hook entries.
# See uninstall.sh for the exact inverse.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
claude_dir="${CM_CLAUDE_DIR:-$HOME/.claude}"
settings="$claude_dir/settings.json"
cmd_src="$repo/claude-config/commands/claude-maxx.md"
cmd_dst="$claude_dir/commands/claude-maxx.md"
wrapper="$repo/scripts/claude-maxx-cmd.sh"

say() { printf '  %s\n' "$*"; }

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required to merge $settings safely." >&2
  exit 1
}

echo "Claude Maxx — installing from $repo"

# 1. Build. Release, so the wrapper's preferred binary path exists and the
#    daemon isn't running unoptimized in the background all day.
echo
echo "[1/4] Building (release)…"
( cd "$repo" && swift build -c release ) || {
  echo "error: swift build failed — fix the build, then re-run this script." >&2
  exit 1
}
say "built $repo/.build/release/ClaudeMaxx"

# 2. Slash command. The command file is the one place that needs an absolute
#    path: a Claude Code command can't locate this repo on its own, and the
#    path also goes in allowed-tools so running it never prompts.
echo
echo "[2/4] Installing /claude-maxx command…"
chmod +x "$wrapper"
mkdir -p "$(dirname "$cmd_dst")"
sed "s|__CM_CMD_PATH__|$wrapper|g" "$cmd_src" > "$cmd_dst"
say "wrote $cmd_dst"

# 3. Hooks. Merged into whatever is already in settings.json — never a
#    wholesale rewrite, since that file holds unrelated user config. Matching
#    is by the loopback URL, so re-running replaces this project's entries and
#    leaves every other hook untouched.
echo
echo "[3/4] Merging hooks into ${settings}…"
CM_SETTINGS="$settings" CM_HOOKS="$repo/hooks-settings.json" python3 <<'PY'
import json, os, shutil, sys

settings_path = os.environ["CM_SETTINGS"]
hooks_path = os.environ["CM_HOOKS"]
MARKER = "127.0.0.1:8765"

with open(hooks_path) as f:
    ours = json.load(f)["hooks"]

if os.path.exists(settings_path):
    with open(settings_path) as f:
        try:
            settings = json.load(f)
        except json.JSONDecodeError as e:
            sys.exit(f"error: {settings_path} is not valid JSON ({e}) — fix it, then re-run.")
    shutil.copy2(settings_path, settings_path + ".claude-maxx.bak")
    print(f"  backed up to {settings_path}.claude-maxx.bak")
else:
    settings = {}
    os.makedirs(os.path.dirname(settings_path), exist_ok=True)

hooks = settings.setdefault("hooks", {})
added = replaced = 0
for event, groups in ours.items():
    existing = hooks.get(event, [])
    # Drop only our own entries, keeping any other tool's hooks for this event.
    kept = []
    for group in existing:
        survivors = [h for h in group.get("hooks", []) if MARKER not in h.get("command", "")]
        if len(survivors) != len(group.get("hooks", [])):
            replaced += 1
        if survivors:
            group = dict(group, hooks=survivors)
            kept.append(group)
        elif not group.get("hooks"):
            kept.append(group)
    if not replaced:
        added += 1
    hooks[event] = kept + groups

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print(f"  {len(ours)} hook events registered ({'updated existing' if replaced else 'newly added'})")
PY

# 4. Start (or restart onto the binary just built).
echo
echo "[4/4] Starting the daemon…"
pkill -f '\.build/(debug|release)/ClaudeMaxx' 2>/dev/null || true
sleep 1
say "$("$wrapper" status)"

cat <<EOF

Done. Next:

  /claude-maxx setup     open a pinned window and sign into the platforms you want
  /claude-maxx ask       chip offers the feed each prompt (default, opt-in)
  /claude-maxx auto      window opens by itself while prompts run
  /claude-maxx off       stop it opening at all

Restart Claude Code (or run /hooks) so it picks up the hook changes.
Logs: ~/Library/Logs/ClaudeMaxx.log
EOF
