# Claude Maxx — working notes

macOS menu bar daemon (Swift/SwiftPM, no Xcode project) that shows a content window only
while a Claude Code prompt is running. It reacts to Claude Code lifecycle hooks over
loopback HTTP on port 8765.

## Setting it up in a fresh clone

```bash
./scripts/install.sh    # build, install /claude-maxx, merge hooks, start daemon
./scripts/doctor.sh     # verify — exits 0 when healthy, 1 when something is broken
```

Then **restart Claude Code**. Hooks are read once at session start, so the session that ran
the install cannot see them — this is the most common "I installed it and nothing happens".

Signing into the content platforms is manual and cannot be automated: `/claude-maxx setup`
opens a pinned window, the human logs in there once, cookies persist.

## After changing any Swift source

The daemon is long-lived and a rebuild does **not** touch the running process:

```bash
swift build -c release && ./scripts/restart.sh
```

Skip this and you are observing the old binary. Every symptom will be a lie — a fix that
"didn't work" is usually a stale daemon. `./scripts/doctor.sh` checks for exactly this
(`binary freshness`).

## Talking to the running daemon

`/cmd` takes its argument as a **query parameter**, not a POST body:

```bash
curl -sG --data-urlencode "arg=status" http://127.0.0.1:8765/cmd
curl -s -X POST http://127.0.0.1:8765/show     # show the window
curl -s http://127.0.0.1:8765/stats.json       # today's derived metrics
```

Endpoints: `/start` `/stop` `/attention` `/cmd` `/show` `/status` `/stats.json` `/dashboard`.

Logs: `~/Library/Logs/ClaudeMaxx.log` — the daemon is headless, so this is the only place
window and navigation behavior can be reconstructed. `cmLog` writes there.

## Tests

`swift test` — 70 tests, all headless-safe. Note two AppKit limits found the hard way:
`NSPanel` and `WKWebView` work fine in the test process, but constructing an `NSStatusItem`
(i.e. a `Menu`) **aborts** it with no window-server connection. That is why
`Menu.readingSubmenu` is static and takes its target.

## Layout

| Path | What |
|---|---|
| `Sources/ClaudeMaxx/Orchestrator.swift` | state machine (IDLE/PENDING/OFFERING/SHOWING/ALERTING), session tracking |
| `Sources/ClaudeMaxx/HookServer.swift` | HTTP parsing + `Router` (pure, socket-free — test here) |
| `Sources/ClaudeMaxx/Channels/` | per-site adapters behind `ContentChannel` |
| `Sources/ClaudeMaxx/Panels/` | `FeedPanel` (content window), `ChipPanel`, `StatsPanel` |
| `Sources/ClaudeMaxx/StatsStore.swift` | append-only JSONL event log; metrics derived at read time |
| `SPEC.md` | the design doc; section numbers (§8.3 etc.) are cited throughout the code |

## Things that will bite you

- **Not sandboxed** — no entitlements file, so local file access needs no bookmarks. Do not
  add an App Sandbox entitlement without reworking `ReadingChannel`'s file loading.
- **`file://` needs `loadFileURL`** — `webView.load(URLRequest:)` refuses file URLs and fails
  *silently*, presenting as a blank window. Channels load through `ContentChannel.load(into:)`.
- **A PDF has no DOM** — injected user scripts, scroll restore, and the attention banner all
  no-op on PDFs. Do not "fix" this with JS; it needs PDFKit.
- **`FeedPanel.shouldLoad` keys on `contentIdentity`, not channel id** — a channel that can
  change content without changing identity (Reading) must fold the selection in, or switching
  items silently keeps the old page.
- **`jq` ships in macOS 15 but not 13/14** — the hooks use it to read `session_id`. Without it
  `sid` arrives empty; `HookServer.sessionID(from:)` maps that to nil so sessions count
  anonymously. Do not "simplify" that back to passing the raw query value.
- **The daemon must keep its own session** — `main.swift` calls `setsid()` at startup because
  every launcher uses `nohup … &`, which leaves it in the spawning hook's process group where a
  group-wide signal kills it mid-prompt. Do not remove it, and do not add a launcher that
  re-parents it into someone else's group.
- **`/claude-maxx`'s own turn must not open a window** — its `UserPromptSubmit` hook sends
  `suppress=1`, decided at submit time. The `/cmd` path cannot do this: a slash command's shell
  body can take longer than `showDelay` to run (measured 17 s vs 4 s), so by the time the command
  arrives the window is already up.
- **Changing `hooks-settings.json` requires users to re-run `install.sh`** — pulling does not
  update `settings.json`. Add a `doctor.sh` check whenever hook behavior changes.
- **Never `print()` from the daemon** — stdout is block-buffered into the log file, so the line
  is lost unless the process exits cleanly. Use `cmLog` (stderr, unbuffered).
- **Style** — comments explain *why*, especially the failure that motivated the code. Match
  that; do not add narration of what a line does.
