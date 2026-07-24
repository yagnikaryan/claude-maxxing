---
name: setup-claude-maxx
description: Install, verify, or repair Claude Maxx in this clone. Use when the user has just cloned the repo, asks to set it up or install it, says the daemon isn't working, nothing appears while prompts run, the window won't close, or asks to uninstall.
---

# Setting up Claude Maxx

Install, verify, and hand off. Three of these steps cannot be done for the user — say so
plainly rather than pretending otherwise.

## 1. Install

```bash
./scripts/install.sh
```

Builds release, writes `~/.claude/commands/claude-maxx.md` pointing at *this* clone, merges
five hook entries into `~/.claude/settings.json` (backing it up first), and starts the daemon.
Idempotent — safe to re-run, and it only replaces its own hook entries.

If it fails, the failure is almost always one of: no Swift toolchain, no `python3`, or
`settings.json` is not valid JSON. Run step 2 to find out which.

## 2. Verify

```bash
./scripts/doctor.sh
```

One `STATUS  check  detail` line per check, a `↳ fix:` line under anything wrong, exit 0 when
healthy. **Read the FAIL lines and act on them** rather than re-running the installer blindly.
WARN means degraded but working; FAIL means broken.

## 3. Tell the user to restart Claude Code

Hooks are read once at session start, so **the current session cannot see the hooks that were
just installed.** Nothing will happen during prompts until they restart. Do not skip this or
report success without saying it — it is the most common false "it doesn't work".

## 4. Hand off the parts you cannot do

- **Platform logins.** `/claude-maxx setup` opens a pinned window; the user signs into
  YouTube / X / Instagram / TikTok themselves, once. Cookies persist. You cannot type
  credentials for them and should not try.
- **Choosing a mode.** `/claude-maxx ask` (default — a chip offers content each prompt, easy
  to ignore) or `/claude-maxx auto` (window opens by itself). `off` disables it. Ask which
  they want rather than picking; this is a preference about their attention.
- **The reading list.** CM menu bar icon → Reading → Add Link… / Add PDF…. Reading starts
  empty and shows a page saying so.

## Diagnosing "it isn't working"

Run `./scripts/doctor.sh` first — it covers most of this. Beyond it:

| Symptom | Likely cause |
|---|---|
| Nothing appears during prompts | Claude Code not restarted since install; or `mode=off` |
| Window stays up after a prompt ends | `Stop` hook missing — check `hooks registered` |
| Behavior doesn't match the code | Stale daemon: `swift build -c release && ./scripts/restart.sh` |
| Window opens then instantly closes | Two Claude sessions sharing a session id — needs `jq`, or the empty-sid path |
| Port 8765 silent but process alive | Something else owns the port: `lsof -nP -iTCP:8765` |

Daemon log: `~/Library/Logs/ClaudeMaxx.log`. It records every window show/hide with the reason,
which is usually enough to tell "we never got the hook" from "we got it and chose not to act".

## Uninstalling

```bash
./scripts/uninstall.sh
```

The exact inverse of the installer. Leaves stats, logins, and settings in place.
