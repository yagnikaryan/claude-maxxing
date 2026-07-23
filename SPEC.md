# Claude Maxx — Technical Architecture & Implementation Spec

**Version:** 0.4 · **Status:** Implementation-ready
**One-liner:** A macOS menu bar daemon that surfaces short-form content (or reading material) only while a Claude Code prompt is running, offers the user a per-prompt choice, and removes the content the instant the agent finishes or needs input.

This document is written to be executed. Every component has its interface, data shapes, and behavior specified precisely enough that a human or an agent can implement it without inventing design decisions. Sections 12–13 are the build plan with acceptance criteria.

---

## 1. Product framing (context for every decision below)

Agentic coding creates dead time in 30-second-to-5-minute chunks — too short to context-switch, long enough to reach for your phone. Once on the phone, the feed decides when you return. This tool inverts that: **the agent's lifecycle bounds the scroll.** Three consequences drive the architecture:

1. The content window must disappear (and optionally return focus to your terminal) on completion with zero user action.
2. The system must never delay, block, or fail a Claude Code prompt. All integration is fail-open.
3. The user is offered a *choice*, not an ambush — opt-in is a first-class mode, not a settings checkbox.

## 2. System topology

Three layers, one-way coupling. Layer 1 knows nothing about content; Layer 2 knows nothing about Claude Code beyond four HTTP signals; Layer 3 knows nothing about either.

```
┌────────────────────────────────────────────────────────────────────┐
│ LAYER 1 · SIGNAL & INTENT (inside Claude Code)                     │
│                                                                    │
│  hooks (automatic, every prompt)         slash command (manual)    │
│  UserPromptSubmit → GET /start?sid=X     /claude-maxx <arg>        │
│  Stop             → GET /stop?sid=X        → GET /cmd?arg=<arg>    │
│  Notification     → GET /attention                                 │
└───────────────────────────────┬────────────────────────────────────┘
                                │ HTTP, loopback only, 127.0.0.1:8765
┌───────────────────────────────▼────────────────────────────────────┐
│ LAYER 2 · ORCHESTRATOR (Swift/AppKit menu bar daemon)              │
│                                                                    │
│  HookServer ─► Router ─► SessionTracker ─► PresentationController  │
│                   │            │                    │              │
│                   ▼            ▼                    ▼              │
│              ModeManager   Watchdog          ChipPanel / FeedPanel │
│                   │                                 │              │
│              SettingsStore                     StatsStore          │
└───────────────────────────────┬────────────────────────────────────┘
                                │ ContentChannel protocol
┌───────────────────────────────▼────────────────────────────────────┐
│ LAYER 3 · CONTENT (channel adapters over one shared WKWebView)     │
│  ShortsChannel · ReadingChannel · XFeedChannel · ReelsChannel ·    │
│  TikTokChannel                                                     │
└────────────────────────────────────────────────────────────────────┘
```

Key insight for §"combining /claude-maxx with /start and /stop": **hooks and the slash command are not peers.** Hooks are the *signal wire* — they fire on every prompt unconditionally and report lifecycle. The slash command is the *intent wire* — it sets what the daemon does with those signals. Both terminate at the same HTTP server, giving one source of truth. Neither ever needs to know about the other.

## 3. Layer 1a — Hooks (the signal wire)

### 3.1 Hook configuration

Lives in `~/.claude/settings.json` (global — this behavior is per-user, not per-repo). Claude Code passes each hook a JSON payload on **stdin** containing at least `session_id`, `transcript_path`, `cwd`, and `hook_event_name`. We extract `session_id` with `jq` so the daemon can track sessions individually.

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command",
      "command": "sid=$(jq -r '.session_id // empty' 2>/dev/null); curl -s --max-time 1 \"http://127.0.0.1:8765/start?sid=$sid\" > /dev/null || true" }]}],
    "Stop": [{ "hooks": [{ "type": "command",
      "command": "sid=$(jq -r '.session_id // empty' 2>/dev/null); curl -s --max-time 1 \"http://127.0.0.1:8765/stop?sid=$sid\" > /dev/null || true" }]}],
    "Notification": [{ "hooks": [{ "type": "command",
      "command": "curl -s --max-time 1 http://127.0.0.1:8765/attention > /dev/null || true" }]}]
  }
}
```

### 3.2 Invariants for this layer

- **Fail-open, always.** `--max-time 1` bounds worst-case added latency to 1 s if the daemon is hung mid-accept; `|| true` guarantees exit code 0 so Claude Code never sees a hook failure. A dead daemon costs ~5 ms (connection refused is instant).
- **No payload beyond `sid`.** The daemon must never depend on prompt text, cwd, or transcript contents. This keeps the contract portable: Cursor, Codex CLI, or a `make` wrapper can integrate with the same three curls.
- **Event semantics.** `Stop` fires at end of *turn* (not per subagent) — correct granularity. `Notification` fires when Claude awaits input/permission — it is an *attention* signal, and the daemon must not treat it as `stop` (the session is still active; the user just needs to look).

## 4. Layer 1b — The `/claude-maxx` slash command (the intent wire)

### 4.1 Command file

`~/.claude/commands/claude-maxx.md` (or per-project `.claude/commands/`):

```markdown
---
description: Control Claude Maxx (off | ask | auto | now | scroll on | scroll off | status)
allowed-tools: Bash(curl:*)
---

!curl -s --max-time 1 "http://127.0.0.1:8765/cmd?arg=$ARGUMENTS" || echo "daemon not running"

Reply with only the command output shown above, verbatim, and nothing else.
```

Mechanics: the `!`-prefixed line executes as bash *before* the prompt is sent, and its stdout is injected into the prompt context; `$ARGUMENTS` interpolates whatever the user typed after `/claude-maxx`; `allowed-tools: Bash(curl:*)` scopes what the command may execute. The trailing instruction pins the model to echoing the daemon's response so the turn costs a few tokens and adds no noise.

### 4.2 Command grammar

| Invocation | Daemon effect | Response |
|---|---|---|
| `/claude-maxx auto` | mode := auto (persisted) | `claude-maxx mode set to auto` |
| `/claude-maxx ask` | mode := ask (persisted, default) | `claude-maxx mode set to ask` |
| `/claude-maxx off` | mode := off; hide chip + window | `claude-maxx mode set to off` |
| `/claude-maxx now` | open window immediately | `opening window` |
| `/claude-maxx setup` | open window immediately (alias of `now` with setup-oriented copy) — also reachable with zero token cost via the menu bar's "Show Window Now" item | `opening window — pick a channel from the CM menu bar icon to log in, then /claude-maxx off to hide it when done (it has no close button by design — non-activating panel, §7)` |
| `/claude-maxx scroll on` / `scroll off` | toggle auto-advance | `auto-advance on/off` |
| `/claude-maxx stats` | none | today's aggregate line (§9.3) |
| `/claude-maxx status` (or bare) | none | one-line state dump |

### 4.3 Known limitations (accepted, by design)

1. **Costs a model turn.** Custom slash commands are prompts under the hood. Acceptable for occasional mode-setting; this is why per-prompt choice lives in the chip (§7), not here.
2. **Cannot run mid-response.** It queues until the current turn ends. Mode changes therefore apply to the *next* prompt. Do not attempt to fix this — no third-party mechanism can inject interactive UI into a streaming turn.
3. **`UserPromptSubmit` fires for slash commands too**, so `/claude-maxx status` itself triggers `/start` then `/stop`. Harmless (the wait is shorter than `showDelay`), but Layer 2's debounce is what makes it harmless — do not remove the debounce without revisiting this.

## 5. Layer 2 — HTTP interface (complete API spec)

Server: raw TCP accept loop (`NWListener`) parsing only the request line; responds `200 text/plain` to everything (fail-open extends to responses — an unknown path returns `unknown endpoint`, never 500). **Bind 127.0.0.1 exclusively, never 0.0.0.0** — anything that can reach this port can pop windows on screen and flip modes.

| Endpoint | Params | Caller | Behavior |
|---|---|---|---|
| `GET /start` | `sid` (optional) | UserPromptSubmit hook | Register session; if count 0→1, begin PENDING (§6) |
| `GET /stop` | `sid` (optional) | Stop hook | Deregister session; if count →0, transition to IDLE |
| `GET /attention` | — | Notification hook | Channel-aware attention behavior (§8.4) |
| `GET /cmd` | `arg` (url-encoded) | /claude-maxx command | Parse grammar (§4.2), mutate mode/window, return message |
| `GET /show` | — | manual/debug | Open window now |
| `GET /status` | — | debug | `mode=ask active_sessions=1 window=hidden auto_advance=true` |
| `GET /stats.json` | — | debug / future dashboards | today's aggregates as JSON (§9.3) |

Session accounting: `sessions: [String: Date]` keyed by `sid` (value = registration time, used by the watchdog) plus `anonCount: Int` for hookless callers. `active = sessions.count + anonCount`. Duplicate `/start` for the same `sid` (e.g., hook retries) overwrites the timestamp — idempotent by construction. `/stop` for an unknown `sid` is a no-op.

**Watchdog:** a 60 s timer expires any session older than `watchdogTimeout` (default 30 min). Handles crashed sessions, force-quits, and laptop sleep, all of which orphan a `/start`. If expiry drives the count to 0, run the full IDLE transition (hide window, snap-back suppressed since the user isn't watching a fresh completion). Without this, one crash pins the window open forever.

## 6. Layer 2 — Presentation state machine

States: `IDLE`, `PENDING`, `OFFERING` (chip visible), `SHOWING` (window visible), `ALERTING` (window visible, video paused, attention requested).

| State | Event | Guard | Action | Next |
|---|---|---|---|---|
| IDLE | /start | mode ≠ off ∧ count 0→1 | capture frontmost app; arm debounce timer (`showDelay`, default 4 s) | PENDING |
| IDLE | /start | mode = off | count only | IDLE |
| PENDING | timer fires | count > 0 ∧ ¬skipped | mode=auto → show window; mode=ask → show chip | SHOWING / OFFERING |
| PENDING | /stop → count 0 | — | cancel timer | IDLE |
| OFFERING | chip "Watch" | — | dismiss chip; show window | SHOWING |
| OFFERING | chip "Skip" | — | dismiss chip; set `skippedThisWait` (cleared on next 0→1 /start) | IDLE* |
| OFFERING | /stop → count 0 | — | dismiss chip | IDLE |
| SHOWING | /stop → count 0 | — | pause video; hide window; activate captured app (snap-back) | IDLE |
| SHOWING | /start | — | count++ only, no visual change | SHOWING |
| SHOWING | /attention | — | pause video (or banner for reading channels); `requestUserAttention` | ALERTING |
| ALERTING | user interacts w/ window | — | resume allowed | SHOWING |
| ALERTING | /stop → count 0 | — | same as SHOWING→IDLE | IDLE |
| any | /cmd arg=off | — | dismiss chip; hide window | IDLE |
| any | /cmd arg=now | — | show window | SHOWING |

\* IDLE with sessions still counting — "Skip" suppresses presentation for the *current wait* only; the counter still tracks reality so a later `/start` while sessions run doesn't re-offer.

Debounce rationale: filters (a) prompts shorter than `showDelay` — exactly the waits where a feed costs more than it fills — and (b) the `/claude-maxx` command's own hook echo (§4.3.3).

**Snap-back:** at PENDING entry, store `NSWorkspace.shared.frontmostApplication`. On SHOWING→IDLE, call `.activate()` on it. This converts "the window closed" into "you're back in your terminal, cursor blinking" — ship default-on. Suppress when IDLE was reached via watchdog expiry or `/cmd off`.

## 7. Layer 2 — ChipPanel (the per-prompt choice)

A ~260×76 pt non-activating `NSPanel` (`.floating` level, top-right corner): title "Claude is working…", two buttons in v0.2 (**Watch** / **Skip**), one button per enabled channel in M2 (**Shorts · Reading · Skip**). Non-activating is mandatory — presenting the chip must not steal keyboard focus from the terminal. Self-dismisses on IDLE. This is the answer to "ask me after I run the prompt": the ask lives *beside* the terminal, not inside it, because no external mechanism can render interactive UI inside a streaming Claude Code turn.

(A native `UNUserNotificationCenter` notification with action buttons is the alternative implementation; it requires a signed `.app` bundle and permission grant, so it's an M3 packaging-time option, not the v0.2 path. The chip needs neither.)

### 7.1 Window geometry & display handling (FeedPanel + ChipPanel)

The window must never render partially off-screen. The rules, in order:

1. **Size against `visibleFrame`, never `frame`.** `NSScreen.visibleFrame` already excludes the menu bar and Dock; `frame` does not. All geometry math uses `visibleFrame` with a fixed `margin` (16 pt) on every edge.
2. **Clamp height first, derive width from aspect.** The content is 9:16, so height is the binding constraint on laptop displays:
   `height = min(desiredHeight, visible.height − 2·margin)`; `width = min(height · 9/16 rounded, visible.width − 2·margin)`; if the width clamp bit, recompute `height = width · 16/9` to preserve aspect. Channels supply `preferredAspect` (§8.1), so reading channels get the same clamp with a ~4:5 ratio.
3. **Anchor bottom-right of the *target screen*:** `origin = (visible.maxX − width − margin, visible.minY + margin)`. Target screen = the screen containing the mouse pointer at show time (`NSEvent.mouseLocation` tested against each `NSScreen.frame`), falling back to `NSScreen.main`. This puts the window where the user is looking on multi-monitor setups instead of always on the primary display.
4. **Validate any restored frame.** `cm.windowFrame` (user-dragged position, §9.1) is applied only if the restored rect, inset by 40 pt, intersects some current screen's `visibleFrame`; otherwise discard it and fall back to rule 3. This handles the classic failure: window saved on an external monitor that's now unplugged.
5. **Re-clamp on display changes.** Observe `NSApplication.didChangeScreenParametersNotification` (fires on monitor plug/unplug, resolution change, Dock resize) and, if the panel is visible, re-run rules 1–4 with an animated `setFrame`. Same observer re-anchors the chip (top-right, rule 3 mirrored to `visible.maxY`).
6. **Let the user resize within bounds.** `styleMask` gains `.resizable`; floor with `minSize` (~240 pt wide) so a resize can't produce an unusable sliver. **Revised post-M2** (see the addendum below): free-form resize, not aspect-locked via `panel.contentAspectRatio` — real usage showed the aspect lock actively fighting sites like Instagram/TikTok, whose desktop layout needs real width to render without clipping, not just a bigger 9:16 rectangle. The channel's `preferredAspect` still shapes the *initial* frame on a fresh open (rule 2 above); it no longer constrains what the user resizes it to afterward, and rule 5's re-clamp on display change preserves whatever shape the user last chose rather than snapping back to the channel default.

AC for the implementing task: on a 13" laptop with the Dock on the bottom, default show fits fully inside the visible area; dragging the window to an external monitor, quitting, unplugging the monitor, and relaunching shows the window on the laptop screen, not off-space.

## 8. Layer 3 — Content channels

### 8.1 Protocol

```swift
protocol ContentChannel {
    var id: String { get }                 // "shorts" | "reading" | "xfeed" | ...
    var displayName: String { get }
    var url: URL { get }
    var preferredAspect: NSSize { get }    // 9:16 video, ~4:5 reading
    var supportsAutoAdvance: Bool { get }
    func userScript() -> WKUserScript      // injected at .atDocumentEnd
    func setAutoAdvance(_ on: Bool, in: WKWebView)   // evaluateJavaScript flag flip
    func pause(in: WKWebView)              // called before hide
    func attention(in: WKWebView)          // channel-appropriate interrupt
}
```

One shared `WKWebView` with a persistent `WKWebsiteDataStore` — login cookies survive relaunch, so each platform is a one-time manual sign-in inside the window (surface "Show window now" for this in first-run onboarding). Expected states per platform: Shorts works logged-out and personalizes when signed in; TikTok's For You feed works logged-out (verified Jul 2026) and personalizes when signed in; Reels effectively requires sign-in. First login from the embedded webview may trigger a platform verification step (email code / "was this you") because the browser surface is unfamiliar — one-time, expected, document it in the README FAQ. Channels own all site-specific DOM knowledge, so a platform redesign breaks one adapter, never the system.

### 8.2 Watch-complete auto-advance (video channels)

Not timer-based. All three platforms render a standard `<video>` element, so *detection* is near-universal; only the *advance action* is per-site. Injected script pattern:

```javascript
(function() {
  if (window.__cmInstalled) return;
  window.__cmInstalled = true;
  window.__cmAutoAdvance = true;              // native toggles this flag
  function advance() { /* PER-SITE, see table */ }
  setInterval(() => {
    if (!window.__cmAutoAdvance) return;
    const v = document.querySelector('video');  // active video is first/only match
    if (!v) return;
    v.loop = false;                             // make `ended` fire
    if (!v.__cmHooked) { v.__cmHooked = true; v.addEventListener('ended', advance); }
    // Fallback: players that re-loop programmatically before `ended`
    if (v.duration && isFinite(v.duration)) {
      if (v.currentTime > v.duration - 0.35 && !v.__cmFired) { v.__cmFired = true; advance(); }
      else if (v.currentTime < 1) { v.__cmFired = false; }
    }
  }, 500);
})();
```

The 500 ms interval re-acquires the `<video>` element because these SPAs recycle player nodes on scroll. Toggling is a native-side `evaluateJavaScript("window.__cmAutoAdvance = false")` — no reload, instant.

| Channel | `advance()` implementation | Stability |
|---|---|---|
| Shorts | `document.querySelector('#navigation-button-down button')?.click()`, fallback `button[aria-label="Next video"]` | High — stable DOM; official embed API exists as plan B |
| Reels | click the desktop next-chevron (right-edge down-arrow; verified present on desktop web, Jul 2026) — select by durable attribute (`aria-label` over CSS class), fallback `scrollBy(innerHeight)` | Medium — real platform-provided control, but exact selector must be read from the live page with the inspector and may shift on redesigns |
| TikTok | click the desktop next-chevron (lower-right; verified present, Jul 2026, including logged-out) — same durable-attribute + scroll-fallback pattern; selectors differ from Reels | Medium — same reasoning |

All three advances are clicks on controls the platforms themselves ship for desktop web — legitimate interactions, not synthetic scroll/keyboard input. Placeholder selectors above are unverified guesses by design: pinning the real Reels/TikTok selectors from the live DOM is an explicit implementation task (§12 M4), not something an agent should trust from this document.

**Timing jitter (required for all video channels):** never call the site's next-control synchronously on `ended`. A click fired at video-end on a perfect metronome is the one remaining machine-legible signature once synthetic input is off the table. `advance()` therefore schedules the click after a uniform random 0.8–3.0 s delay, and skips the auto-advance entirely with small probability (~1 in 12), letting the video sit until the user or the next completion moves it. Both parameters live beside the selectors in each channel adapter.

Policy for Reels/TikTok: manual scrolling must always work (it's just a webview); auto-advance is a degradable extra that falls back to scroll when the chevron isn't found. Never automate login on any platform — the user signs in by hand, once.

### 8.3 Reading channels

**ReadingChannel:** user-supplied URL list (paste-in v1; Safari Reading List via `~/Library/Safari/Bookmarks.plist` + Full Disk Access, or a read-later API, later). `advance()` = next article. Persist scroll offset per URL in `UserDefaults` (`cm.scroll.<urlhash>`) on hide, restore on show — a 90-second wait resumes mid-paragraph.
**XFeedChannel:** loads `x.com/home`; auto-scroll = `setInterval(() => scrollBy({top: 2, behavior:'instant'}), 30)` for a slow crawl, with `mouseenter` pausing and `mouseleave` resuming. No completion concept — it's ambient. Easiest channel to build; good second channel after Shorts.

### 8.4 Attention behavior is channel-aware

On `/attention`: video channels pause playback (polite interrupt); reading/X channels overlay a dismissible injected banner ("Claude needs input") *without* touching scroll position — yanking text mid-sentence is hostile. Both paths also call `NSApp.requestUserAttention(.criticalRequest)`.

## 9. Persistence & metrics

### 9.1 SettingsStore

**SettingsStore** (`UserDefaults`, prefix `cm.`): `cm.mode` (string: off|ask|auto, default ask) · `cm.channel` (string id, default shorts) · `cm.autoAdvance` (bool, default true) · `cm.showDelay` (double, default 4.0) · `cm.dailyCapMinutes` (int, 0 = off) · `cm.snapBack` (bool, default true) · `cm.windowFrame` (string, via `NSWindow.saveFrame`) · `cm.scroll.<urlhash>` (double).

### 9.2 StatsStore — event log

Append-only JSONL at `~/Library/Application Support/ClaudeMaxx/stats.jsonl`. **Event sourcing, not pre-aggregated counters:** raw events are logged at each state-machine transition and every metric is derived at read time. This means new metrics can be invented later over historical data, and a crash can at worst lose one in-flight episode, never corrupt totals. Local only; never transmitted.

Every record carries `t` (ISO8601) and `type`. Event types and their emit points:

| `type` | Emitted at | Extra fields |
|---|---|---|
| `wait` | count →0 (IDLE entry) — one per wait episode, spanning first `/start` to last `/stop` | `seconds` |
| `content` | window hide — one per SHOWING episode | `seconds`, `openedBy ∈ {auto, chip, cmd, menu, http}`, `closedBy ∈ {stop, cmd, watchdog, cap, quit}`, `channel` |
| `chip` | chip presented / button tapped | `action ∈ {offered, watch, skip}` |
| `advance` | injected JS detects watch-complete; posted natively via `WKScriptMessageHandler` (`window.webkit.messageHandlers.cm.postMessage('advance')`) | — |
| `attention` | `/attention` received | — |

Note `wait` and `content` are independent dimensions: waits are logged in every mode including `off` (the baseline), content only when the window actually showed. That asymmetry is what makes the ratio meaningful.

### 9.3 Derived metrics

Computed by scanning the day's events (file is small; full scan is fine until M3, then cache by day):

| Metric | Derivation | Why it's the interesting one |
|---|---|---|
| **Content-to-wait ratio** | Σ content.seconds / Σ wait.seconds | The headline: "how much of Claude's thinking time did I spend scrolling" — containment made visible |
| Waits / total wait time | count(wait), Σ wait.seconds | "Claude worked 47 min across 12 prompts today" |
| Videos completed | count(advance) | The guilt-meter unit for video channels |
| Opt-in rate | chip.watch / chip.offered | Reveals whether ask-mode is friction or a genuine choice |
| Skip rate | chip.skip / chip.offered | High skip rate → user should just set mode=off; surface that suggestion |
| Interrupts | count(attention) | How often Claude needed you mid-scroll |
| Per-channel split (M2) | group content by `channel` | Shorts vs reading time |
| Median wait (M2) | percentile over wait.seconds | Tune `showDelay` from real data |

Surfaces, cheapest first: **menu bar** — disabled first menu item, `Today: 12m content / 47m waiting (12 waits)`, refreshed on IDLE; **`/claude-maxx stats`** — one-line aggregate in the terminal via `/cmd`; **`GET /stats.json`** — machine-readable day summary (`{"waits":12,"wait_seconds":2820,"content_seconds":720,"content_to_wait_ratio":0.26,"videos_completed":14,...}`) which is the contract any future dashboard builds on; **M3 dashboard** — local HTML page (menu → "Open stats") rendering week/month trends from the JSONL, no server beyond a file URL.

### 9.4 Daily cap (consumes §9.2 data)

Sum today's `content.seconds`; on breach force SHOWING→IDLE with `closedBy: "cap"`, suppress PENDING until local midnight, menu bar shows "capped."

## 10. Repository layout

```
claude-maxx/
├── Package.swift                     # SwiftPM, macOS 13+, single executable target
├── Sources/ClaudeMaxx/
│   ├── main.swift                    # entry point
│   ├── HookServer.swift              # M1 split
│   ├── Orchestrator.swift            # SessionTracker + state machine
│   ├── Channels/                     # M2
│   └── Panels/                       # FeedPanel, ChipPanel
├── claude-config/
│   ├── commands/claude-maxx.md       # copy to ~/.claude/commands/
│   └── (hooks live in hooks-settings.json)
├── hooks-settings.json               # merge into ~/.claude/settings.json
├── scripts/install.sh                # M3: jq-merge hooks + copy command + login item
└── README.md
```

### 10.1 Setup & distribution (GitHub-ready)

Target user experience — three commands from README to working:

```bash
git clone https://github.com/<you>/claude-maxx && cd claude-maxx
./scripts/install.sh
swift run          # (or `open ClaudeMaxx.app` once M3 packaging lands)
```

**`scripts/install.sh` algorithm** (idempotent — safe to re-run after every update):

1. *Preflight:* verify macOS ≥ 13 (`sw_vers`), Swift toolchain (`xcode-select -p`), and `~/.claude/` exists (else print "install Claude Code first" and exit 1). Check for `jq`; if absent, print a `brew install jq` recommendation but **continue** — see degradation note below.
2. *Backup:* copy `~/.claude/settings.json` to `settings.json.bak.<epoch>` if it exists.
3. *Merge hooks* with python3 (ships with dev tools; avoids requiring jq for install itself): load existing settings JSON (or `{}`), deep-merge our three hook entries **only if** no existing hook command contains `127.0.0.1:8765` (the idempotency test — never duplicate, never clobber the user's other hooks), write back pretty-printed.
4. *Install command:* copy `claude-config/commands/claude-maxx.md` to `~/.claude/commands/claude-maxx.md` (overwrite ours, never touch other files).
5. *Verify:* start nothing; print the checklist — `swift run`, then `curl http://127.0.0.1:8765/status`, then `/hooks` inside Claude Code to confirm registration, then a >4 s prompt.

**`scripts/uninstall.sh`:** remove exactly the hook entries whose command contains `127.0.0.1:8765`, delete `~/.claude/commands/claude-maxx.md`, leave stats and settings backups in place, print what was removed. A tool that installs into someone's Claude config *must* ship a clean reverse gear — it's the difference between a repo people try and one they trust.

**Graceful degradation without `jq`:** the hook line `sid=$(jq -r ... 2>/dev/null)` fails silently when jq is missing, so `sid` is empty and the daemon falls back to anonymous counting (§5) — everything works, only per-session watchdog precision is lost. Document this in README rather than hard-requiring jq.

**README structure (the repo's front door):** one-paragraph pitch with the containment framing → demo GIF (chip appears, window opens, prompt finishes, window vanishes, terminal refocuses — this GIF *is* the marketing) → the three-command quickstart → `/claude-maxx` command table (§4.2) → config knobs → "How it works" diagram (§2) → uninstall → FAQ covering the YouTube login step, the jq note, and "does this send my prompts anywhere?" (no — §11, link it).

**Trust posture for a public repo:** state explicitly in README that the daemon binds loopback only, receives no prompt text, and writes stats only to a local file — and that `install.sh` touches exactly two paths in `~/.claude/`, lists them, and backs up before writing. People are rightly wary of scripts that edit their agent config; preempt the audit.

## 11. Security & privacy invariants

Loopback bind only; no auth on the API is acceptable *only* because of that bind — revisit if the bind ever changes. No prompt text, transcript contents, or cwd ever reaches the daemon. Stats never leave the machine. Webview cookies live in the app's own data store, isolated from Safari/Chrome. Never automate credential entry into any platform.

## 12. Build plan (agent-executable tasks with acceptance criteria)

**M1 — daily driver** (v0.2 prototype exists; harden it)
1. *Split main.swift* per §10 layout. AC: `swift build` clean; behavior unchanged.
2. *Session IDs + watchdog* (in prototype; verify). AC: two concurrent `curl /start?sid=a`, `/start?sid=b` → window persists after one `/stop`, hides after both; a lone `/start` with no `/stop` hides the window within `watchdogTimeout`+60 s.
3. *Snap-back.* AC: with Terminal frontmost, `/start`→window→`/stop` re-activates Terminal; watchdog-driven hide does not.
4. *SettingsStore.* AC: mode, autoAdvance, window frame survive relaunch.
5. *StatsStore* (in v0.3 prototype; verify). AC: a full wait+watch cycle appends `chip`(offered), `chip`(watch), `content`, and `wait` events; `/claude-maxx stats` and `/stats.json` totals match the raw file.
6. *Window geometry* per §7.1 (clamp, mouse-screen anchoring, frame validation, display-change observer, resizable with aspect lock). AC: as stated in §7.1.
7. *App bundle:* `Info.plist` with `LSUIElement=true`, login-item registration (`SMAppService`). AC: app launches at login with no Dock icon.

**M2 — channels & choice**
8. *Extract `ContentChannel`*; move Shorts logic in. AC: protocol per §8.1; Shorts behavior unchanged.
9. *XFeedChannel* per §8.3. AC: slow scroll, hover-pause, banner on `/attention`.
10. *ReadingChannel* with scroll persistence. AC: hide/show restores position within one line.
11. *Chip → channel picker.* AC: one button per enabled channel + Skip; selection opens that channel.
12. *Menu: channel selector; per-channel stats split.* AC: menu stats line breaks out channels once >1 channel has data.

**M3 — containment release**
13. *Daily cap* per §9.4. AC: breach closes window, suppresses until midnight, menu shows capped state.
14. *install.sh + uninstall.sh* per §10.1. AC: install idempotent on re-run (no duplicate hooks); uninstall removes exactly the two installed artifacts and preserves user hooks; a settings.json with pre-existing unrelated hooks survives an install/uninstall round-trip byte-identical apart from our entries.
15. *Packaging:* codesign, notarize, Homebrew cask. AC: `brew install --cask claude-maxx` on a clean machine → working in <2 min.
16. *Stats dashboard:* local HTML page (menu → "Open stats") charting week/month trends from stats.jsonl via /stats.json-style aggregation. AC: renders offline, matches /claude-maxx stats for today.
17. *(Optional)* Notification-with-buttons as chip alternative, now that the bundle is signed.

**M4 — expansion:** Reels/TikTok channels — pin the live next-chevron selectors with the web inspector (durable attributes, not classes), wire the shared jitter parameters, verify logged-in session persistence per platform. AC: a full watch-through on each platform advances via button click with jittered timing; removing the button (simulated) falls back to scroll. Also: `claude-maxx exec -- <cmd>` CLI wrapping arbitrary long processes with `/start`//`/stop`; hook recipes for other agents.

## 13. Test matrix (manual, pre-agent-CI)

| Scenario | Expected |
|---|---|
| Prompt < 4 s | Nothing appears (debounce) |
| Prompt > 4 s, mode=ask | Chip at ~4 s; Watch opens window; window gone + terminal refocused on completion |
| Prompt > 4 s, mode=auto | Window at ~4 s, no chip |
| `/claude-maxx off` then prompt | Nothing appears; `/status` shows sessions counting |
| 2 sessions, staggered stops | Window hides only after the last stop |
| `/claude-maxx status` alone | One-line state echoed; no window flash |
| Kill daemon, run prompt | Prompt latency unchanged (fail-open) |
| Claude asks permission mid-run | Video pauses + attention bounce; window stays |
| Watch a short to the end, scroll on | Auto-advances within ~0.5 s of end; `advance` event logged |
| Full cycle then `/claude-maxx stats` | Line shows 1 wait, content minutes > 0, 1 offered / 1 watched |
| 13" laptop, Dock at bottom, default show | Window fully inside visible area, nothing clipped |
| Saved frame on unplugged monitor, relaunch | Window appears on remaining screen (frame validation) |
| Re-run install.sh twice, then uninstall.sh | No duplicate hooks; settings restored minus our entries |

## 14. Risks

**DOM fragility** (Reels/TikTok): materially reduced now that all three platforms are advanced via their own desktop next-buttons rather than synthetic input, but the Reels/TikTok selectors still shift on redesigns — contained by durable-attribute selection, the scroll fallback, and channel isolation, so breakage degrades to manual scroll, never an outage. **Hook API drift:** the three events used are among Claude Code's most stable and documented; fail-open means drift breaks the toy, never the tool. **Slash-command mechanics drift** (frontmatter format, `!` execution): pin behavior with the §13 test `/claude-maxx status` case. **Perception risk** ("TikTok while AI works" reads as a gag): lead public framing with containment — chip opt-in, guilt meter, daily cap, reading channel. **Webview login friction:** first-run tooltip pointing at "Show window now" for the one-time login.

## 15. Decisions log

| # | Decision | Rationale |
|---|---|---|
| 1 | Local HTTP over Unix socket/files | curl one-liners in hooks and command; debuggable; portable to other agents |
| 2 | Hooks = signal, /claude-maxx = intent, one server | Single source of truth; hooks never grow; command grammar extends freely |
| 3 | Chip panel over terminal-injected choice | No third-party mechanism can render interactive UI in a streaming turn |
| 4 | Chip over UNUserNotification (v0.2) | Notifications require signed bundle + permission; chip needs neither |
| 5 | `ended`-event advance over fixed timer | Real watch-complete semantics; universal detection, per-site action only |
| 6 | Counter+sid dictionary+watchdog | Self-heals crashes/sleep; duplicate-start idempotent |
| 7 | Non-activating panels throughout | Never steal keyboard focus from the terminal |
| 8 | Menu bar daemon over Chrome extension | Extensions can't float over a terminal or own window lifecycle |
| 9 | Pause-and-hide over kill-webview | Preserves login + feed position across waits |
| 10 | Shorts first, X feed second | Highest DOM stability; easiest ambient channel |
| 11 | Containment framing (chip, cap, meter) | Differentiation and the version you'd keep using |
| 12 | Advance = click platform-shipped desktop next-buttons, with jittered timing | Verified present on all three platforms (Jul 2026); legitimate interaction path removes the synthetic-input problem; jitter removes the metronome signature |

---

## Post-M2 addition: setup / debug entry point

Added after the initial M1+M2 pass, prompted by needing to log into each
channel's platform (and to debug the window) without waiting on a real
Claude Code prompt each time:

- **Menu item "Show Window Now"** calls `Orchestrator.showNow(openedBy: .menu)`
  directly from the menu bar — zero token cost, no prompt needed, works with
  zero active sessions. This is the primary way to reach the first-run login
  flow referenced in §8.1/§14's "Show window now" tooltip.
- **`/claude-maxx setup`** — a `/cmd` grammar alias of `now` with copy aimed at
  first-run login, for parity when driving from inside a Claude Code session.
- **Live channel switching while already open** — `Orchestrator.switchChannelIfShowing()`.
  Previously, picking a channel from the menu while the window was already
  SHOWING/ALERTING was silently dropped (`handleShowNow`'s `.showing,
  .alerting: break` case never re-presented) — a user could only ever log
  into whichever channel happened to be active on first show. The menu's
  `selectChannel` now calls this after persisting `settings.channel`, so
  switching between Shorts/X/Reading to log into each one works within a
  single open setup session. It is a pure re-point of the current episode —
  no new `content` stats event, no state-machine transition. Scoped to
  SHOWING only, not ALERTING: re-presenting fresh (unpaused) content while
  ALERTING would leave `state` stuck at `.alerting`, and a genuinely new
  `/attention` would then no-op against it (`handleAttention`'s
  `state == .showing` guard, §6) — so channel switching during an attention
  alert stays a persist-only no-op, same as while idle.
- **`FeedPanel.performShow` only recomputes/`setFrame`s geometry on a fresh
  open** (`!isVisible`), not on every `show(channel:)` call. Needed once
  channel switching could re-invoke `show` on an already-visible window —
  otherwise it would re-resolve from the last-*persisted* `settings.
  windowFrame` and silently discard a resize/reposition made earlier in the
  same still-open episode.
- The window has no close button by design (`styleMask` is
  `[.nonactivatingPanel, .resizable]`, never `.closable`, and it's shown via
  `orderFrontRegardless()` so it never becomes key) — `/claude-maxx off` (or
  quitting the app) is the only way to end a setup session opened this way.
- **Drag handle.** `FeedPanel` had no way to be moved: no `.titled` style
  mask (no title bar) and `isMovableByWindowBackground` was never set, and
  wouldn't have helped anyway since the `WKWebView` fills the entire content
  view, leaving no true "window background" for AppKit to hit-test. Fixed
  with a thin overlay strip (`DragHandleView`, layered *over* the webview
  rather than pushing it down, so the §7.1 aspect/geometry math is
  untouched) whose `mouseDown` calls `window?.performDrag(with:)` — the
  reliable way to make an arbitrary borderless-panel view draggable. Also
  shows the active channel's `displayName`, since channels otherwise have no
  on-window chrome at all.

## Post-M4 partial addition: Reels and TikTok channels (scroll-only)

`ReelsChannel` and `TikTokChannel` were added ahead of full M4, at the
user's request, with a deliberate scope cut: **`advance()` is scroll-only**
(`window.scrollBy({top: window.innerHeight, behavior: 'instant'})`), not the
chevron-click §8.2 describes. Live DOM investigation during this addition
(narrow automated-browser viewport, no accessible names on TikTok's action
rail, no working candidate found; Reels needs an actual account login to
test at all) confirmed §8.2's own warning that these selectors must come
from live inspection, not be guessed — so rather than ship an unverified
selector, both channels use the spec's own documented fallback as their only
mechanism for now. Everything else matches `ShortsChannel`'s pattern exactly
(same `ended`/currentTime detection, same jitter, same `cm` message handler
for the `advance` stats event) — swapping in a real chevron click later
(§12 M4) only means replacing `cmClickNext`'s body in each channel file.

`cmClickNext()` reports success honestly — it compares `window.scrollY`
before/after the scroll and only fires the `advance` stats event (§9.2) if
the page actually moved, rather than unconditionally claiming success like
a real button click would. This matters because Reels' desktop layout is
commonly a fixed single-reel viewer with no `window`-level scroll at all
(chevron/keyboard nav instead) — if that's the case here, `scrollBy` is a
silent no-op and `videosCompleted` correctly stays flat for that channel
rather than being inflated by a click that did nothing. TikTok's feed is
more plausibly page-scrollable. Neither could be confirmed with live-page
access during this build; verifying which is true (and pinning the real
chevron either way) is the actual M4 follow-up.

**Known limitation, not fixed:** `ChipPanel.contentSize`'s width grows
linearly with `ChannelRegistry.all.count` (one button per channel + Skip) —
5 channels now makes it ~520pt wide, up from ~352pt at 3. `WindowGeometry`'s
aspect-locked clamp (§7.1) could shrink the whole chip, including its 76pt
height, on an unusually narrow display (e.g. a tight split-screen). Not
addressed here — a real fix (wrapping to multiple rows, or a scrollable
row) is more scope than "add two channels" warrants; flagging so it isn't
silently forgotten if a 6th channel is ever added.

## Post-M4 bugfix round: browser escape, resize lock, window never closing

Three real bugs reported after using the app, all fixed together:

- **"TikTok opened in the actual browser."** `FeedPanel`'s `WKWebView` had no
  `uiDelegate`. Per WebKit's default behavior on macOS, a `target="_blank"`
  link or `window.open()` call (TikTok's login modal has "Continue with
  Facebook/Google/Apple" buttons that do this) falls through to the OS
  opening it in the user's *default* browser — a different cookie jar than
  the app's isolated `WKWebsiteDataStore`, so any login there never carries
  back into the app. Fixed with a `WKUIDelegate` conformance implementing
  `webView(_:createWebViewWith:for:windowFeatures:)`: loads the request in
  the same shared webview and returns `nil` instead of letting it escape.
  **Known trade-off, accepted:** a popup-based OAuth flow that relies on
  `window.opener`/`postMessage` back to the original page (rather than a
  redirect) can end up on a dead-end "you may close this window" page
  instead of a real popup — still fully contained in the app's own webview
  (so at worst it's a stuck page you can reload/navigate away from), which
  is strictly better than the previous behavior of silently logging in
  somewhere the app can never see.
- **"I can't resize to fit my desktop."** `contentAspectRatio` was locking
  every live user resize to the channel's fixed aspect (9:16 for video
  channels) — exactly what made Instagram/TikTok's desktop layout clip,
  since those sites need real width, not just a bigger 9:16 rectangle.
  Removed both assignments (`configure()` and `performShow`); `preferredAspect`
  still shapes the *initial* frame on a fresh open, it just no longer
  constrains resizing afterward. This required a matching fix in
  `WindowGeometry.reclamped` (§7.1 rule 5's display-change safety net) —
  without it, `reclamped` would silently snap a freely-resized window back
  to the channel's fixed aspect on the next monitor plug/unplug or
  resolution change, re-introducing the same complaint one event later.
  `reclamped` now derives its clamp aspect from the *current frame's own*
  proportions instead of the channel default, so it only ever shrinks an
  oversized frame to fit a smaller screen — never reshapes it.
- **"It opens, but doesn't close after the prompt ends."** The real root
  cause: opening the window manually (menu's "Show Window Now" or
  `/claude-maxx now`/`setup`) with zero active sessions puts `state` into
  `.showing`. `handleStart` used to call `enterPending()` unconditionally on
  every 0→1 session transition, regardless of current `state` — so a real
  prompt starting afterward clobbered `state` from `.showing` back to
  `.pending`, even though the window was still visibly open. When that
  prompt's `/stop` later drove the count back to 0, `handleWaitEnded` saw
  `.pending`/`.offering` instead of `.showing` and took the chip-dismiss
  cleanup path — `hideWindowAction()` never ran, and the window stayed open
  forever. Fixed by guarding `enterPending()` on `state == .idle`: a 0→1
  transition while state is already SHOWING/ALERTING (the manual-open case)
  now just lets the session count update without disturbing the
  presentation state, so the window continues as part of that same episode
  and closes normally once the real session ends.

## Naming conventions for this implementation

- Product/app name: **Claude Maxx**. Executable target / module: `ClaudeMaxx`.
- Slash command: `/claude-maxx`, file `claude-config/commands/claude-maxx.md`.
- `UserDefaults` key prefix: `cm.` (e.g. `cm.mode`, `cm.channel`, `cm.windowFrame`).
- Stats directory: `~/Library/Application Support/ClaudeMaxx/stats.jsonl`.
- Injected JS globals use the `__cm` prefix (`__cmInstalled`, `__cmAutoAdvance`, `__cmHooked`, `__cmFired`), and the `WKScriptMessageHandler` name is `cm` (`window.webkit.messageHandlers.cm.postMessage(...)`).
- HTTP port (127.0.0.1:8765) and all endpoint paths are unchanged from the spec text above.
