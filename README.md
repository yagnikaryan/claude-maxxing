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
git clone https://github.com/yagnikaryan/claude-maxxing && cd claude-maxxing
./scripts/install.sh
./scripts/doctor.sh     # verify — exits 0 when healthy
```

Then restart Claude Code (or run `/hooks`) so it picks up the new hooks, and run
`/claude-maxx setup` to sign into the platforms you want. That's the whole install.

**Or let Claude do it.** Open Claude Code in the clone and say *"set this up"* — the repo ships
a `setup-claude-maxx` skill and a `CLAUDE.md`, so your agent knows the install, the verify step,
and the parts only you can do (platform logins, picking a mode). `./scripts/doctor.sh` is
written to be read by an agent: one `STATUS  check  detail` line per check, a `↳ fix:` line
under anything wrong, and an exit code — so "did it work?" is checkable rather than guessed.

`install.sh` builds the release binary, writes `~/.claude/commands/claude-maxx.md` with the paths
pointing at *your* clone, merges this project's five hook entries into `~/.claude/settings.json`,
and starts the daemon. It's safe to re-run — hooks are matched by this project's own markers, so a
re-run replaces our entries and leaves every other hook you have alone, and `settings.json` is
backed up to `settings.json.claude-maxx.bak` first. Requires `python3` (preinstalled on macOS) to
edit that JSON safely.

There's no `.app`, no installer package, and nothing signed to trust — the daemon is a plain binary
inside your clone, started from there. [`scripts/uninstall.sh`](./scripts/uninstall.sh) is the
exact inverse and leaves your stats, logins, and settings in place.

**Two ways to run it, both supported.** Pick by how much you want it around:

- **Always on.** Leave **"Start with Claude Code"** enabled (menu bar item, or
  `scripts/claude-maxx-hook.sh enable`). A `SessionStart` hook starts the daemon whenever you open
  Claude Code, so its lifetime matches the only thing it reacts to and you never think about it.
- **On demand.** Turn that toggle off and nothing runs until you ask — no daemon, no menu bar icon,
  nothing in the background after a reboot. When you want it, the mode command *is* the start
  command: `/claude-maxx ask` starts the daemon and sets the mode in one step, because the wrapper
  launches the binary first whenever nothing answers. `/claude-maxx quit` puts it away again.

The one thing to know about on-demand: with the daemon down there's no menu bar icon, so the GUI
routes (Show Window Now, the channel picker, the Reading list) aren't reachable until you've
started it with a command or [`scripts/start.sh`](./scripts/start.sh).

The checkbox reflects what is actually in `settings.json`, and because a running Claude Code
session reads its hooks at startup, a change takes effect from the *next* session. During
development, `swift run` in the foreground works too.

There is deliberately no "Launch at Login". With no packaged `.app` there's no bundle identity for
macOS to register, so a login item records the path of whatever binary was running and goes stale
on a clean or release rebuild — and it would keep a daemon alive all day for something that only
reacts to Claude Code.

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
| `/claude-maxx quit` | stop the daemon process entirely | `stopping the daemon — …` |
| `/claude-maxx scroll on` / `scroll off` | toggle auto-advance on the video channels (applies live if the window is open; X/Reading have no auto behavior) | `auto-advance on/off` |
| `/claude-maxx stats` | none | today's aggregate line (waits, content/waiting minutes, chip opt-in, videos completed) |
| `/claude-maxx dashboard` | open the stats dashboard in its own native floating panel | `opening stats dashboard` |
| `/claude-maxx status` (or bare) | none | one-line state dump, prefixed with the running version (`window=visible-pinned` = a setup/now window that ignores prompt endings) |

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

## The Reading channel

Reading is your own list rather than someone's feed: web articles and local files (PDFs, mostly)
held together and picked from **CM menu bar icon → Reading**. The submenu lists what you've added
— **Add Link…** takes a pasted URL or a file path, **Add PDF…** opens a file picker. Choosing an
entry switches to Reading and opens it; **Remove** drops the selected one. An empty list says so
in the window instead of showing a blank page.

Two things worth knowing:

- **Scroll position is remembered for web pages, not PDFs.** A PDF rendered by WebKit isn't a DOM,
  so the injected scroll-restore script never runs — PDFs reopen at the top. Web articles resume
  where you left off, across hide/show and across relaunch.
- **The list stores paths, not file handles.** Move or rename a file and the entry goes stale; the
  window will tell you which one rather than going blank.

There's deliberately no auto-advance here — reaching the end of a page isn't a request for a
different one. You move between entries yourself.

## Starting and stopping

There is no login item and nothing registered with the OS, so after a reboot the daemon is simply
not running until something starts it. Three ways, in the order you'll actually use them:

| | |
|---|---|
| **Start with Claude Code** (menu bar toggle) | a `SessionStart` hook starts the daemon whenever you open Claude Code. This is the "never think about it" option, and takes effect from the *next* session. `scripts/claude-maxx-hook.sh enable\|disable\|status` is the same switch from a terminal. |
| `/claude-maxx <anything>` | starts it on demand. There is no `/claude-maxx start` — a command needs a daemon to receive it — so the wrapper launches the binary first whenever nothing answers, waits, and re-sends your subcommand. `/claude-maxx status` therefore both starts the daemon and reports on it. |
| [`./scripts/start.sh`](./scripts/start.sh) | the same from a terminal; says `already running` rather than starting a second one. |
| `./scripts/restart.sh` | restarts it onto a newly built binary (what you want after changing code). |

To stop it: `/claude-maxx quit`, **Quit Claude Maxx** in the menu bar, or
[`./scripts/stop.sh`](./scripts/stop.sh). All three leave your hooks, logins, and stats alone — it starts
again by any of the routes above.

**"Fully off" means one of three different things**, so pick the one you want:

- **Stop showing content, keep everything running.** `/claude-maxx off`. The daemon stays up and
  keeps counting sessions; it just never opens a window or offers a chip. This is the reversible
  one — `/claude-maxx ask` brings it back.
- **Stop the process too.** `/claude-maxx quit` (or `./scripts/stop.sh`, or menu → Quit), *and* turn
  off "Start with Claude Code" so a new session doesn't bring it back. Nothing then runs until you deliberately start it.
- **Remove it from this machine.** [`./scripts/uninstall.sh`](./scripts/uninstall.sh) — deletes the
  slash command and strips the hooks, leaving your stats, logins, and settings in place. Then
  delete the clone.

## Config knobs

All settings live in `UserDefaults` under the `cm.` prefix (`SettingsStore`):

| Key | Default | Meaning |
|---|---|---|
| `cm.mode` | `ask` | `off` \| `ask` \| `auto` |
| `cm.channel` | `shorts` | active `ContentChannel` id |
| `cm.autoAdvance` | `true` | auto-advance to the next video on completion (video channels only — X and Reading deliberately have no auto-scroll) |
| `cm.showDelay` | `4.0` (s) | debounce before the chip/window appears |
| `cm.dailyCapMinutes` | `0` (off) | daily content-time cap in minutes |
| `cm.snapBack` | `true` | re-activate your previously-frontmost app on hide |
| `cm.windowFrame` | unset until first hide | last dragged/resized window position |
| `cm.reading.urls` | `[]` | reading list — web links and local file paths, in one list |
| `cm.reading.currentIndex` | `0` | which reading-list entry is selected |
| `cm.scroll.<urlhash>` | `0.0` | per-article scroll offset (reading channel, web pages only) |

**Start with Claude Code:** the menu bar's toggle isn't a `cm.*` default either — it lives in
`~/.claude/settings.json` as a `SessionStart` hook, so the setting is visible and editable in the
same place as every other hook. `scripts/claude-maxx-hook.sh status|enable|disable` is the same
control from a terminal. Re-running `install.sh` turns it back on, since that's the default for a
fresh install.

## How it works

```
LAYER 1 · SIGNAL & INTENT (inside Claude Code)
  hooks (automatic, every prompt)       slash command (manual)
  SessionStart     → start the daemon   /claude-maxx <arg> → /cmd?arg=<arg>
  UserPromptSubmit → /start?sid=X
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
                    │  Reels + TikTok share ScrollFeedScript
  injected JS → `cm` message bridge → advance / advance-failed / idle
```

Channel scripts report back over a `cm` `WKScriptMessageHandler`: a confirmed advance becomes a
`.advance` stats event (what `videos_completed` counts), and a stuck channel reports why instead of
failing silently.

Hooks are the *signal wire* — they fire on every prompt unconditionally and report lifecycle only
(`sid`, nothing else). `/claude-maxx` is the *intent wire* — it's how you tell the daemon what to
do with those signals (mode, channel, one-off "show now"). Both terminate at the same
loopback-only HTTP server (`HookServer` → `Router` → `Orchestrator`), so there's one source of
truth and neither wire needs to know the other exists.

## Stats

Every state transition appends one event to a local JSONL log
(`~/Library/Application Support/ClaudeMaxx/stats.jsonl`): waits (a prompt running), content
episodes (window open, with channel and how it opened/closed), chip offers/answers, confirmed
video advances, and interrupts. Metrics are always derived from the raw events at read time —
nothing pre-aggregates, so the numbers can't drift from the log.

Three read surfaces, thinnest first:

- `/claude-maxx stats` — one line, today only.
- `GET http://127.0.0.1:8765/stats.json` — today's derived metrics as JSON.
- **The dashboard** — `/claude-maxx dashboard`, or **Stats Dashboard…** in the menu bar. Opens a
  native floating panel (no browser; the same page is also served at
  `http://127.0.0.1:8765/dashboard`). Headline content-to-wait ratio, totals, an hour×day heatmap
  of when content plays (switchable to a Mon–Sun weekly-pattern view, with empty hours collapsed
  by default), content-vs-waiting by day, and the per-channel split — over a selectable 7/14/30-day
  or all-time range. Every chart has a table twin, and the page is fully self-contained HTML:
  no CDN, no external requests, regenerated from the log each time it opens.

Definitions worth knowing: **waiting** counts only time a Claude prompt was actually running
(`/start`→`/stop`); **content** counts time the window was open, which includes pinned
setup/`now` windows that run outside any prompt — so a content:wait ratio above 1.0 means the
window was open beyond prompt cycles, not that the math is wrong.

## Uninstall

```bash
./scripts/uninstall.sh
```

Stops the daemon, deletes `~/.claude/commands/claude-maxx.md`, and strips this project's five hook
entries from `~/.claude/settings.json` — leaving any other hooks you have untouched, with a backup
alongside. Then delete the clone whenever you like.

Your data is deliberately left in place, so a reinstall picks up where you left off. The script
prints all four locations on exit: stats (`~/Library/Application Support/ClaudeMaxx/stats.jsonl`),
logins (`~/Library/HTTPStorages/ClaudeMaxx.binarycookies`, `~/Library/WebKit/ClaudeMaxx`), settings
(`defaults delete ClaudeMaxx`), and logs (`~/Library/Logs/ClaudeMaxx.log`).

## FAQ

**I pulled a new version and something behaves the same as before.** Hooks are written into
`settings.json` at install time, so pulling doesn't update them — re-run `./scripts/install.sh` and
restart Claude Code. `doctor.sh` flags this as `hooks up to date`.

**Something's wrong and I don't know what.** Run [`./scripts/doctor.sh`](./scripts/doctor.sh). It
checks the toolchain, the build, whether the running daemon is actually *this* clone's binary and
newer than your sources, the loopback port, the slash command, and the hook entries — printing a
`↳ fix:` line under anything wrong and exiting non-zero if the daemon can't work as-is. It's
read-only, so it's always safe to run.

**I changed the code and nothing changed.** The daemon is long-lived and a rebuild doesn't touch
the running process, so you're watching the old binary. `swift build -c release &&
./scripts/restart.sh`. This is the single most convincing false negative in the project — a fix
that "didn't work" is usually a stale daemon, which is why `doctor.sh` checks binary freshness.

**Two Claude Code sessions and the window closes while one is still working.** Fixed, but worth
knowing why: the hooks read `session_id` with `jq`, which ships in macOS 15 but not in 13 or 14.
Without it every session sent an empty id and collided on one tracking slot, so the first prompt to
finish drove the count to zero. Empty ids now count anonymously, which handles concurrency
correctly. On 13/14, installing `jq` additionally restores per-session identity, which the
30-minute watchdog uses to expire one stuck session without touching the others.

If it happens anyway, the log now says why: every `/start` and `/stop` records the session id and
the resulting count, so a close is attributable to the count genuinely reaching zero — or not.

**The window opened but never closes when the prompt ends.** Run `/claude-maxx status` and check
three things. (1) `window=visible-pinned`: it's a setup/"Show Window Now" window, which ignores
prompt endings by design — `/claude-maxx hide` closes it. (2) `active_sessions` > 1: the window
closes only when the *last* active Claude Code session finishes its turn — another terminal
mid-prompt keeps it open, correctly. (3) An interrupted turn (Esc) never fires the `Stop` hook, so
that session stays counted until its next completed turn, its exit (`SessionEnd` hook), or the
30-minute watchdog. And remember `mode=off` means no window ever opens in the first place.

**Reels/TikTok don't auto-advance.** They should — verified against both live feeds. Advancing is
still scroll-based rather than a "next" chevron click (per SPEC §8.2 those selectors must be
pinned from live DOM inspection, not guessed), but the scroll now targets the feed's *own*
scrolling container. Scrolling `window` moved nothing on either site, and the success check
compared `querySelector('video')` — the first video in a virtualized feed, not the one on screen —
so advances silently reported failure forever. Both channels share
[`ScrollFeedScript`](./Sources/ClaudeMaxx/Channels/ScrollFeedScript.swift) so a fix can't reach one
and miss the other.

If a channel really is stuck, it now says so: it emits an idle heartbeat naming what it sees
(`no video (0 in DOM)`, `current paused t=0.0/180.0`) to `~/Library/Logs/ClaudeMaxx.log`, and each
advance records which mechanism worked (`advance via container DIV#column-list-container`). A
channel that goes quiet in that log is advancing normally.

**Can I type into the window? My keystrokes go to my editor instead.** Click directly into the
field. The panel never grabs focus just by appearing, so it can't hijack your typing mid-prompt —
but it also can't receive keystrokes until you deliberately click it. Because this is a
non-activating panel in an accessory (no Dock icon) app, clicking alone used to make it key
*within the app* without making the app active, and macOS delivers keystrokes to the active app —
so after clicking away and back, typing landed in whatever you left (an SMS code going to your
terminal instead of the code box). Clicking a text field now activates the app; clicking a video
deliberately does not, so watching never steals focus from your editor.

**A platform (YouTube/X) asks me to verify it's me the first time.** Expected, one-time friction —
the embedded webview looks unfamiliar to the platform, so it may ask for an email code or "was
this you?" confirmation. Click **"Show Window Now"** in the menu bar (or run `/claude-maxx setup`)
to open the window on demand, pick each channel from the menu to sign into it in turn — cookies
persist in the app's own data store after that.

**I logged in (even did the captcha) but I'm logged out again right away.** Three separate causes
were behind this, all fixed — if you're on an older build, rebuild before debugging further.

WKWebView's default UA lacks Safari's `Version/x Safari/x` suffix, which Meta treats as an
untrusted embedded browser. More subtly, the window used to reload the feed whenever the current
URL differed from the channel's — true of *every* in-site page, including a login form — and that
check ran on every prompt, so your next message to Claude navigated away from a half-finished
login. A login that never completes never gets a session, which reads exactly like "it didn't
save". Finally, `window.open()` popups were flattened into the main webview, severing
`window.opener`; Meta's `auth_platform` handoff posts the session back through it, so popups now
open in their own window ([`PopupPanel`](./Sources/ClaudeMaxx/Panels/PopupPanel.swift)).

Once you're in, it stays: cookies live in the app's persistent data store
(`~/Library/HTTPStorages/ClaudeMaxx.binarycookies`) and survive relaunches. To confirm a real
session rather than a partial login, look for a `sessionid` cookie — `csrftoken` alone means the
flow never finished. Note that WebKit keys storage by *process name* for an unbundled binary, so
M3's packaged `.app` will change that path and cost you one final re-login.

**Instagram's captcha route still fails for me.** Known, unfixed. The `auth_platform/recaptcha`
path can bounce back to `/?e=<code>` without issuing a session; the verification-**code** route
completes normally. If you get routed to a captcha and it fails, retry — Instagram usually offers
the code path instead.

**Does this send my prompts anywhere?** No. The daemon binds `127.0.0.1` exclusively (never
`0.0.0.0`) and never receives prompt text, transcript contents, or your working directory — hooks
pass only a session id (`sid`). Stats are written only to a local JSONL file and never
transmitted. Webview cookies live in the app's own isolated `WKWebsiteDataStore`, separate from
Safari/Chrome.

**What if `jq` isn't installed?** The hooks degrade gracefully: `sid=$(jq -r ... 2>/dev/null)`
fails silently and falls back to anonymous session counting — everything still works, you just
lose per-session watchdog precision. `brew install jq` if you want it, but it's not required.

**Does anything run when Claude Code isn't open?** No. There's no login item and no launch agent —
the only thing that starts the daemon is the `SessionStart` hook (or you, via `/claude-maxx`), and
"Quit Claude Maxx" in the menu ends it. Turning the toggle off leaves nothing behind but the
absence of a hook entry; `uninstall.sh` removes the rest.

## Trust posture

Loopback-only bind; no prompt text, transcript, or cwd ever reaches the daemon; stats never leave
the machine. Nothing runs at login or in the background when Claude Code isn't open. `install.sh`
touches exactly two paths under `~/.claude/`: it merges hook entries into
`settings.json` (backed up first, other hooks preserved) and writes one file at
`commands/claude-maxx.md`. Nothing else in `~/.claude/` is read or written, nothing is installed
outside your clone, and `uninstall.sh` reverses both. Read the two scripts before running them —
they're short, and you should not run an installer you haven't looked at.

## Development

```bash
swift build
swift test
swift run
```

**Logs.** The daemon runs headless behind a menu bar icon, so it writes a trace to
`~/Library/Logs/ClaudeMaxx.log` (the wrapper script points its stdout/stderr there): every
navigation, every reload decision and why, and each channel's advance / advance-failed / idle
heartbeat. `tail -f ~/Library/Logs/ClaudeMaxx.log` is the fastest way to see what a channel is
actually doing — most of the login and auto-advance bugs above were only diagnosable from it.

**Inspecting a page.** The feed webview is `isInspectable`, so Safari can attach to it: enable
Safari → Settings → Advanced → "Show features for web developers", then Safari → Develop →
**ClaudeMaxx** → the page. There is no right-click "Inspect Element" inside the window itself.

See `SPEC.md` for the full technical architecture, state machine, and build plan. This repo is
mid-way through the plan's **M2 → M3** milestones (channels/chip picker and
`install.sh`/`uninstall.sh` done; the daily cap still ahead). Signed `.app` packaging and a
Homebrew cask are deliberately *not* planned — this is a clone-and-run project.
