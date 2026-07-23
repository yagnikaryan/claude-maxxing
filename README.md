# Claude Maxx

Agentic coding creates dead time in 30-second-to-5-minute chunks — too short to context-switch,
long enough to reach for your phone. Once you're on the phone, the feed decides when you come
back. Claude Maxx inverts that: **the agent's lifecycle bounds the scroll.** A menu bar daemon
watches Claude Code's own lifecycle hooks and surfaces a small content window *only* while a
prompt is running, then removes it — with zero user action — the instant the agent finishes or
needs your input. You're offered a choice, not an ambush: opt-in ("ask" mode, a small chip you can
ignore) is the default, not a settings checkbox you'll never find.

**Demo:** *(coming with packaging — no signed `.app` yet to record from in this environment.)* What
it will show: chip appears in the top-right corner while Claude is mid-prompt → you click Watch →
a small window opens bottom-right → the prompt finishes → the window vanishes and your terminal
refocuses, all without touching the mouse again.

## Quickstart

```bash
git clone https://github.com/<you>/claude-maxx && cd claude-maxx
swift build
swift run
```

`scripts/install.sh` / `scripts/uninstall.sh` (SPEC §12, M3) will eventually automate the two
one-time steps below and aren't in this repo yet — for now, do them by hand:

1. Merge [`hooks-settings.json`](./hooks-settings.json) into `~/.claude/settings.json` (or run
   `/hooks` inside Claude Code afterward to confirm the four entries registered).
2. Copy [`claude-config/commands/claude-maxx.md`](./claude-config/commands/claude-maxx.md) to
   `~/.claude/commands/claude-maxx.md`.

Signed, notarized `.app` packaging and a Homebrew cask are also M3 — until then, `swift run` (or a
locally built `.build/*/ClaudeMaxx` binary) is how you run the daemon.

## `/claude-maxx` command

Once the command file is installed, control the daemon from inside a Claude Code session:

| Invocation | Daemon effect | Response |
|---|---|---|
| `/claude-maxx auto` | mode := auto (persisted) | `claude-maxx mode set to auto` |
| `/claude-maxx ask` | mode := ask (persisted, default) | `claude-maxx mode set to ask` |
| `/claude-maxx off` | mode := off; hide chip + window | `claude-maxx mode set to off` |
| `/claude-maxx now` | open window immediately | `opening window` |
| `/claude-maxx setup` | open window immediately, for first-run login | numbered setup walkthrough (see below) |
| `/claude-maxx hide` (or `done`) | close the window, keep the current mode | `window hidden — mode stays ask` |
| `/claude-maxx scroll on` / `scroll off` | toggle auto-advance (applies live if the window is open) | `auto-advance on/off` |
| `/claude-maxx stats` | none | today's aggregate line |
| `/claude-maxx status` (or bare) | none | one-line state dump (`window=visible-pinned` = a setup/now window that ignores prompt endings) |

Mode changes apply to the *next* prompt (custom slash commands can't act mid-turn — see SPEC
§4.3). Running the command is itself a prompt, so its own `/start`→`/stop` fire too — every
subcommand except `now`/`setup` suppresses its own turn's window/chip so a settings tweak never
flashes content at you. `now`/`setup` are the exception on purpose: an instant window is the point.

**Setup, step by step** (`/claude-maxx setup`, or the menu bar's **"Show Window Now"** item — the
menu route costs zero tokens and works with zero active sessions):

1. The content window opens immediately and stays **pinned** open — it ignores prompt endings, so
   you can take your time. (`/status` shows this as `window=visible-pinned`.)
2. Pick a channel from the **CM menu bar icon** (Shorts / X / Reading / Reels / TikTok). The open
   window switches live — no need to close and reopen between platforms.
3. Log into each platform you want, directly in the window. One-time: cookies persist in the
   app's own data store across relaunches.
4. Want to see autoscroll? `/claude-maxx scroll on` applies to the open window immediately.
5. When you're done, `/claude-maxx hide` closes the window (it has no close button by design —
   it's a non-activating panel that never steals focus), and your mode is untouched. Then pick
   how Claude Maxx behaves during real prompts: `/claude-maxx ask` (a chip offers the feed each
   prompt) or `/claude-maxx auto` (window opens by itself).

A pinned setup window blocks the normal per-prompt flow while it's up (no chip will appear, and
prompt endings won't close it) — that's what `hide` is for. `/claude-maxx off` also closes it, but
additionally turns the whole feature off, which is usually not what you want after setup.

## Config knobs

All settings live in `UserDefaults` under the `cm.` prefix (`SettingsStore`):

| Key | Default | Meaning |
|---|---|---|
| `cm.mode` | `ask` | `off` \| `ask` \| `auto` |
| `cm.channel` | `shorts` | active `ContentChannel` id |
| `cm.autoAdvance` | `true` | auto-advance to next video/article on completion |
| `cm.showDelay` | `4.0` (s) | debounce before the chip/window appears |
| `cm.dailyCapMinutes` | `0` (off) | daily content-time cap in minutes |
| `cm.snapBack` | `true` | re-activate your previously-frontmost app on hide |
| `cm.windowFrame` | unset until first hide | last dragged/resized window position |
| `cm.scroll.<urlhash>` | `0.0` | per-article scroll offset (reading channel) |

**Login item:** the menu bar's "Launch at Login" toggle isn't a `cm.*` default — it's a real
per-user macOS setting backed by `SMAppService`, visible in System Settings → General → Login
Items & Extensions. Pre-M3 (no packaged `.app` yet), toggling it on registers whatever binary path
is currently running (e.g. `swift run`'s `.build/*/debug/ClaudeMaxx`), so a clean/release rebuild
changes that path and may require re-toggling it. Toggling it off in the menu removes the entry.

## How it works

```
LAYER 1 · SIGNAL & INTENT (inside Claude Code)
  hooks (automatic, every prompt)       slash command (manual)
  UserPromptSubmit → /start?sid=X       /claude-maxx <arg> → /cmd?arg=<arg>
  Stop             → /stop?sid=X
  SessionEnd       → /stop?sid=X
  Notification     → /attention
                    │  HTTP, loopback only, 127.0.0.1:8765
LAYER 2 · ORCHESTRATOR (this daemon)
  HookServer → Router → Orchestrator (session tracking, state machine)
                            │
                       ChipPanel / FeedPanel, SettingsStore, StatsStore
                    │  ContentChannel protocol
LAYER 3 · CONTENT (channel adapters over one shared WKWebView)
  ShortsChannel · XFeedChannel · ReadingChannel · ReelsChannel · TikTokChannel
```

Hooks are the *signal wire* — they fire on every prompt unconditionally and report lifecycle only
(`sid`, nothing else). `/claude-maxx` is the *intent wire* — it's how you tell the daemon what to
do with those signals (mode, channel, one-off "show now"). Both terminate at the same
loopback-only HTTP server (`HookServer` → `Router` → `Orchestrator`), so there's one source of
truth and neither wire needs to know the other exists.

## Manual uninstall

`scripts/uninstall.sh` doesn't exist yet (M3); to remove Claude Maxx's hooks by hand:

1. In `~/.claude/settings.json`, remove the four hook entries whose `command` contains
   `127.0.0.1:8765` (`UserPromptSubmit`, `Stop`, `SessionEnd`, `Notification`), leaving any other
   hooks you have untouched.
2. Delete `~/.claude/commands/claude-maxx.md`.

Stats (`~/Library/Application Support/ClaudeMaxx/stats.jsonl`) and settings are left in place —
nothing here deletes your data.

## FAQ

**The window opened but never closes when the prompt ends.** Run `/claude-maxx status` and check
three things. (1) `window=visible-pinned`: it's a setup/"Show Window Now" window, which ignores
prompt endings by design — `/claude-maxx hide` closes it. (2) `active_sessions` > 1: the window
closes only when the *last* active Claude Code session finishes its turn — another terminal
mid-prompt keeps it open, correctly. (3) An interrupted turn (Esc) never fires the `Stop` hook, so
that session stays counted until its next completed turn, its exit (`SessionEnd` hook), or the
30-minute watchdog. And remember `mode=off` means no window ever opens in the first place.

**Reels/TikTok don't auto-advance to the next video when one ends — they just scroll.** Known,
intentional for now. Per SPEC §8.2, the real "next video" chevron selectors on those two platforms
have to be pinned from live DOM inspection, not guessed — Reels also needs an actual account login
to test meaningfully. Rather than ship a guessed selector, both channels currently use the spec's
own documented scroll fallback as their *only* advance mechanism. Everything else (jitter, `ended`
detection, stats reporting) is already wired, so swapping in a real chevron click later is a
one-line change once someone pins the live selector.

**A platform (YouTube/X) asks me to verify it's me the first time.** Expected, one-time friction —
the embedded webview looks unfamiliar to the platform, so it may ask for an email code or "was
this you?" confirmation. Click **"Show Window Now"** in the menu bar (or run `/claude-maxx setup`)
to open the window on demand, pick each channel from the menu to sign into it in turn — cookies
persist in the app's own data store after that.

**Does this send my prompts anywhere?** No. The daemon binds `127.0.0.1` exclusively (never
`0.0.0.0`) and never receives prompt text, transcript contents, or your working directory — hooks
pass only a session id (`sid`). Stats are written only to a local JSONL file and never
transmitted. Webview cookies live in the app's own isolated `WKWebsiteDataStore`, separate from
Safari/Chrome.

**What if `jq` isn't installed?** The hooks degrade gracefully: `sid=$(jq -r ... 2>/dev/null)`
fails silently and falls back to anonymous session counting — everything still works, you just
lose per-session watchdog precision. `brew install jq` if you want it, but it's not required.

**Does the "Launch at Login" toggle leave something behind?** Yes, deliberately — it's backed by
real OS state (`SMAppService`, visible under System Settings → General → Login Items &
Extensions), not an app-internal preference. Toggling it back off in the menu removes the entry
cleanly. Pre-M3 it's tied to whichever binary path registered it (see Config knobs above), so a
clean rebuild may need a re-toggle.

## Trust posture

Loopback-only bind; no prompt text, transcript, or cwd ever reaches the daemon; stats never leave
the machine. Manual setup (until `scripts/install.sh` lands) touches exactly two paths under
`~/.claude/`: it merges hook entries into `settings.json` and adds one file at
`commands/claude-maxx.md`. Nothing else in `~/.claude/` is read or written.

## Development

```bash
swift build
swift test
swift run
```

See `SPEC.md` for the full technical architecture, state machine, and build plan. This repo is
mid-way through the plan's **M2 → M3** milestones (channels/chip picker done; daily cap and
`install.sh`/`uninstall.sh`/packaging still ahead).
