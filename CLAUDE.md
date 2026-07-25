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

`swift test` — 72 tests, all headless-safe. Note two AppKit limits found the hard way:
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
  no-op on PDFs, so Reading opens them at the top every time. Do not "fix" this with JS, and do not
  fake it with `#page=`: WebKit honors that on load but never reports the page you are actually on,
  so it would restore a position it cannot capture. A real fix means a PDFKit `PDFView` alongside
  the shared webview, which changes `FeedPanel`'s one-webview design.
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
- **A manually-opened window must survive its own prompt's `/stop`** — `/claude-maxx now` and
  `setup` are themselves submitted as Claude Code prompts, so their `UserPromptSubmit`/`Stop` hooks
  fire around that same short-lived turn. Without `Orchestrator.isManuallyPinned` the window closes
  the instant that curl-and-echo turn ends, which defeats the entire point of "open it so I can log
  in". A pinned episode closes only on `/claude-maxx off` or the watchdog.
- **Changing `hooks-settings.json` requires users to re-run `install.sh`** — pulling does not
  update `settings.json`. Add a `doctor.sh` check whenever hook behavior changes.
- **Never `print()` from the daemon** — stdout is block-buffered into the log file, so the line
  is lost unless the process exits cleanly. Use `cmLog` (stderr, unbuffered).
- **Three `WKWebViewConfiguration` lines are load-bearing for login and playback**, and none of
  them look it. `WKWebsiteDataStore.default()` (not `.nonPersistent()`) is what makes sign-in
  survive relaunch — storage lands under `~/Library/WebKit/ClaudeMaxx`, keyed by process name, even
  unbundled. `applicationNameForUserAgent = "Version/… Safari/…"` is required because WKWebView's
  default UA stops at `(KHTML, like Gecko)`, the fingerprint of an embedded webview: Instagram runs
  the full password+captcha dance and then silently withholds the `sessionid` cookie, so login can
  never persist no matter how the data store is set. `mediaTypesRequiringUserActionForPlayback = []`
  is required because nothing in this window ever supplies a user gesture — TikTok sat paused at
  t=0 forever, which also starved the watch-complete check driving auto-advance, and because Reels
  was allowed under the default it presented as a TikTok-only scrolling bug. Hiding still
  force-pauses (`hide()` plus the channels' `__cmHidden` poll), so audio does not leak.
- **`FeedPanel` must override `canBecomeKey`** — a borderless panel defaults to false, which
  leaves WebKit treating every page as blurred: login forms never take a cursor ("I can't type into
  the Instagram login"). This does not violate SPEC decision #7, because the panel still never
  *takes* key on show — `performShow` uses `orderFrontRegardless`, never `makeKeyAndOrderFront`.
- **`SIG_IGN` before `DispatchSourceSignal`** — the default action for SIGTERM/INT/HUP kills the
  process before the source ever fires, so `applicationWillTerminate` never runs and the daemon
  vanishes with no record. `installSignalHandlers` suppresses the default first, on purpose.
- **`NSApp.terminate` is a request, not an exit** — `applicationShouldTerminate` can defer it and
  a modal run loop (`Menu`'s `NSAlert`/`NSOpenPanel`) can swallow the queued call. `quit` therefore
  goes through `QuitTerminator`: ask AppKit, then `exit(0)` from a **global** queue if still alive.
  Stage 2 must never be scheduled on main — a blocked main thread is the case it exists for.
- **A `/claude-maxx` reply is not evidence** — the command file makes Claude report the wrapper's
  output, and a reply invented when that output is missing reads exactly like a real one. `daemon
  started` for a daemon that never started sends you hunting for a bug in the daemon instead of in
  the command that failed to fire. Confirm with `pgrep -f ClaudeMaxx` or the log before believing it
  — that includes replies *you* just produced.
- **Style** — comments explain *why*, especially the failure that motivated the code, and stay
  short. The durable place for a failure is this list, not a long block mid-file; add it here and
  leave a one-line pointer at the code. Do not add narration of what a line does.
