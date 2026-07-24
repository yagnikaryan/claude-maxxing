import AppKit
import Foundation

// MARK: - PresentationState (SPEC §6)

/// Presentation states of the content window/chip. Matches SPEC §6 exactly:
/// IDLE, PENDING (debounce armed), OFFERING (chip visible), SHOWING (window
/// visible), ALERTING (window visible, paused, attention requested).
enum PresentationState: String {
    case idle
    case pending
    case offering
    case showing
    case alerting
}

// MARK: - SessionTracker (SPEC §5)

/// Pure value type mirroring SPEC §5's session accounting. No locking of its
/// own — the owner (Orchestrator) serializes all access on its queue.
struct SessionTracker {
    private(set) var sessions: [String: Date] = [:]
    private(set) var anonCount: Int = 0

    var activeCount: Int { sessions.count + anonCount }

    /// Registers a session. Idempotent: a duplicate `sid` just overwrites its
    /// timestamp (§5). Returns `true` iff this call is the 0→1 transition.
    @discardableResult
    mutating func start(sid: String?, now: Date) -> Bool {
        let wasZero = activeCount == 0
        if let sid {
            sessions[sid] = now
        } else {
            anonCount += 1
        }
        return wasZero && activeCount > 0
    }

    /// Deregisters a session. No-op for an unknown `sid` (§5). Returns `true`
    /// iff this call drives the count to 0.
    @discardableResult
    mutating func stop(sid: String?) -> Bool {
        if let sid {
            guard sessions.removeValue(forKey: sid) != nil else { return false }
        } else {
            guard anonCount > 0 else { return false }
            anonCount -= 1
        }
        return activeCount == 0
    }

    /// Watchdog primitive: drops sid-keyed sessions older than `cutoff`.
    /// Anonymous count is never watchdog-expired — only tracked sids can be
    /// orphaned (§5). Returns `true` iff this call drives the count to 0.
    @discardableResult
    mutating func expireStale(before cutoff: Date) -> Bool {
        let wasNonZero = activeCount > 0
        sessions = sessions.filter { $0.value >= cutoff }
        return wasNonZero && activeCount == 0
    }
}

// MARK: - IDLE-transition notification (SPEC §9.3)

/// Posted every time Orchestrator's state machine (re-)enters IDLE, so Menu
/// can refresh its disabled stats item "on IDLE transitions" per §9.3
/// without polling. Posted on Orchestrator's private background `queue` —
/// observers must hop to main before touching AppKit.
extension Notification.Name {
    static let claudeMaxxDidBecomeIdle = Notification.Name("com.claudemaxx.didBecomeIdle")
}

// MARK: - Orchestrator

/// Owns session accounting, the presentation state machine (§6), and the
/// watchdog (§5). Single serial queue for all mutation, matching the
/// concurrency model HookServer already uses for Router.
final class Orchestrator {
    private let settings: SettingsStore
    private let stats: StatsStore
    private let watchdogTimeout: TimeInterval
    private let watchdogInterval: TimeInterval
    private let now: () -> Date
    private let chipPresenterFactory: () -> ChipPresenting
    private let feedPresenterFactory: () -> FeedPresenting

    private let queue = DispatchQueue(label: "com.claudemaxx.orchestrator")

    /// Lazily constructed so `Orchestrator()`'s init never touches AppKit
    /// unless a chip is actually shown — keeps `Router()`'s default-
    /// constructed Orchestrator (e.g. in HookServerTests) safe to build
    /// without a live window server.
    private lazy var chipPresenter: ChipPresenting = {
        let presenter = chipPresenterFactory()
        presenter.onSelect = { [weak self] channelID in self?.chipSelect(channelID: channelID) }
        presenter.onSkip = { [weak self] in self?.chipSkip() }
        return presenter
    }()

    /// Lazily constructed for the same reason as `chipPresenter` above.
    /// `FeedPresenting` has no callbacks, so no wiring beyond construction.
    private lazy var feedPresenter: FeedPresenting = {
        feedPresenterFactory()
    }()

    private var tracker = SessionTracker()
    private var state: PresentationState = .idle

    /// Set at every 0→1 `/start` (independent of mode — `wait` events are
    /// logged in every mode per §9.2). Cleared when the count reaches 0 again.
    private var waitStartedAt: Date?
    /// For the `content` event's `seconds`/`openedBy`.
    private var showingStartedAt: Date?
    private var showOpenedBy: ContentOpenedBy?
    /// Set by chip "Skip", cleared on next 0→1 `/start` (§6 footnote).
    private var skippedThisWait = false
    /// Captured at PENDING entry, for snap-back.
    private var capturedFrontmostApp: NSRunningApplication?
    /// True for a content episode opened via a manual override (`.cmd`,
    /// `.http`, `.menu` — Show Window Now / `/claude-maxx now`/`setup` /
    /// `/show`), false for the automatic per-prompt flow (`.auto`, `.chip`).
    /// Set in `beginShowing`, read by `handleWaitEnded`. Exists because
    /// `/claude-maxx now`/`setup` is itself submitted as a Claude Code
    /// prompt — its own `UserPromptSubmit`/`Stop` hooks fire around that
    /// same short-lived turn, so without this flag the window it just
    /// opened would immediately close again the instant that trivial
    /// curl-and-echo turn ends, defeating the entire point of a manual
    /// "open it so I can log in" override. A manually-pinned episode is
    /// closed only by an explicit `/claude-maxx off` (`handleCommandOff`)
    /// or the watchdog safety net — never by an incidental `/stop`.
    private var isManuallyPinned = false

    /// The showDelay debounce, one-shot.
    private var showTimer: DispatchSourceTimer?
    /// Repeating watchdog, started in init.
    private var watchdogTimer: DispatchSourceTimer?

    init(
        settings: SettingsStore = .shared,
        stats: StatsStore = .shared,
        watchdogTimeout: TimeInterval = 1800,
        watchdogInterval: TimeInterval = 60,
        now: @escaping () -> Date = Date.init,
        chipPresenterFactory: @escaping () -> ChipPresenting = { ChipPanel() },
        feedPresenterFactory: @escaping () -> FeedPresenting = { FeedPanel() }
    ) {
        self.settings = settings
        self.stats = stats
        self.watchdogTimeout = watchdogTimeout
        self.watchdogInterval = watchdogInterval
        self.now = now
        self.chipPresenterFactory = chipPresenterFactory
        self.feedPresenterFactory = feedPresenterFactory
        startWatchdog()
    }

    deinit {
        showTimer?.cancel()
        watchdogTimer?.cancel()
    }

    // MARK: Public API

    func start(sid: String? = nil, suppress: Bool = false) -> String {
        queue.sync { handleStart(sid: sid, suppress: suppress) }
    }

    func stop(sid: String?) -> String {
        queue.sync { handleStop(sid: sid) }
    }

    func attention() -> String {
        queue.sync { handleAttention() }
    }

    func commandOff() {
        queue.sync { handleCommandOff() }
    }

    /// Covers both `/cmd now` (`.cmd`) and `/show` (`.http`).
    func showNow(openedBy: ContentOpenedBy) {
        queue.sync { handleShowNow(openedBy: openedBy) }
    }

    /// Re-presents the current settings while a content episode is already
    /// open: re-resolves `settings.channel` and re-points the shared webview
    /// (Menu's channel picker during a setup/login session — multiple
    /// platforms to sign into in one open episode) and re-applies
    /// `settings.autoAdvance` live (`/claude-maxx scroll on|off` while the
    /// window is up — without this the toggle only took effect on the *next*
    /// open, making autoscroll untestable in a setup session). A no-op
    /// outside SHOWING, including ALERTING: re-presenting fresh content
    /// there would leave `state` at `.alerting` (still "paused, awaiting
    /// attention") while the new channel is actually unpaused and playing,
    /// and `handleAttention`'s `state == .showing` guard (§6) would then
    /// no-op a genuinely new `/attention` until the user interacts — so a
    /// refresh during an attention alert stays a persist-only no-op, same
    /// as while idle. Deliberately does not touch state/timers/stats — it
    /// is not a new content episode, just a live re-point of the current one.
    func refreshIfShowing() {
        queue.sync { handleRefreshIfShowing() }
    }

    /// Suppresses presentation for the current wait only — cancels PENDING
    /// or dismisses OFFERING without touching the session count. Called by
    /// Router for every non-window-opening `/cmd` arg (`scroll on`, `status`,
    /// `ask`, …): the `/claude-maxx` command is itself a Claude Code prompt,
    /// so its own `UserPromptSubmit` arms the debounce, and a model turn
    /// routinely outlives `showDelay` — without this, a plain settings
    /// command flashes the window (auto) or chip (ask) for its own turn.
    /// SHOWING/ALERTING are left alone: an episode already on screen (e.g.
    /// a pinned setup window, or a real prompt's content in another session)
    /// must not be killed by an incidental settings command.
    func suppressCurrentWait() {
        queue.sync { handleSuppressCurrentWait() }
    }

    /// ChipPanel hook, wired via `chipPresenter.onSelect` above — not called
    /// from HookServer (channel taps happen on the chip, not over HTTP).
    func chipSelect(channelID: String) {
        queue.sync { handleChipSelect(channelID: channelID) }
    }

    /// Future ChipPanel hook — not wired from HookServer yet.
    func chipSkip() {
        queue.sync { handleChipSkip() }
    }

    /// Future FeedPanel hook (ALERTING→SHOWING) — not wired from HookServer yet.
    func userDidInteractWithWindow() {
        queue.sync { handleUserInteraction() }
    }

    var activeSessionCount: Int {
        queue.sync { tracker.activeCount }
    }

    /// Chip-only OFFERING does NOT count as window-visible — matches the
    /// existing `/status` contract where `window=hidden` while a chip could
    /// be shown.
    var isWindowVisible: Bool {
        queue.sync { state == .showing || state == .alerting }
    }

    /// True only while a *manually pinned* episode is on screen (Show Window
    /// Now / `/claude-maxx now`/`setup`) — the kind that ignores prompt
    /// endings and only closes via `/claude-maxx off`/`hide` or the
    /// watchdog. Surfaced in `/status` so "why isn't the window closing?"
    /// is answerable without reading this file.
    var isWindowPinned: Bool {
        queue.sync { (state == .showing || state == .alerting) && isManuallyPinned }
    }

    // MARK: Private handlers (assume already on `queue`)

    /// Every inline `state = .idle` assignment goes through this so Menu's
    /// "refreshed on IDLE transitions" AC (§9.3) has exactly one signal to
    /// observe. Posting on every idle-entry (including already-idle
    /// defensive paths) is harmless — Menu's handler just recomputes stats
    /// from StatsStore, which is idempotent.
    private func enterIdle() {
        state = .idle
        NotificationCenter.default.post(name: .claudeMaxxDidBecomeIdle, object: nil)
    }

    /// `suppress` marks a turn that must never present content — set by the
    /// `UserPromptSubmit` hook when the prompt is itself a `/claude-maxx`
    /// command.
    ///
    /// The old `suppressCurrentWait()` path could not do this. It runs when
    /// the `/cmd` request *arrives*, and a slash command's shell body can take
    /// far longer than `showDelay` to execute — measured at 17 s against a 4 s
    /// debounce. So `/claude-maxx off` armed the debounce at submit, opened
    /// the window 4 s later, played content for 12 s, and only then applied
    /// the command that closed it: the window the command existed to shut
    /// off. Deciding at submit time is the only point early enough.
    ///
    /// Confined to the 0→1 transition so a command typed in one session
    /// cannot cancel a window another session's prompt legitimately owns.
    private func handleStart(sid: String?, suppress: Bool = false) -> String {
        let t = now()
        let becameActive = tracker.start(sid: sid, now: t)
        // Session accounting decides whether the window is up, but left no
        // trace at all — so "the window closed while I was mid-prompt" was
        // unanswerable after the fact. Log every transition with the id and
        // the resulting count: a close is legitimate only when the count
        // genuinely reached 0, and this is the only way to tell that from a
        // miscounted session.
        cmLog("session start sid=\(sid ?? "<anon>") active=\(tracker.activeCount)\(becameActive ? " (0→1)" : "")\(suppress ? " suppressed" : "")")
        if becameActive {
            waitStartedAt = t
            skippedThisWait = suppress
            // Only from a genuine idle start: a 0→1 transition can arrive
            // while a manually-opened window is already showing, and
            // clobbering that to .pending made the state machine forget it was
            // in a content episode — the eventual /stop then took the
            // chip-dismiss path, never called hideWindowAction(), and the
            // window stayed open forever.
            if settings.mode != .off && state == .idle && !suppress {
                enterPending(at: t)
            }
        }
        return "session started (active=\(tracker.activeCount))"
    }

    private func enterPending(at t: Date) {
        capturedFrontmostApp = NSWorkspace.shared.frontmostApplication
        state = .pending
        armShowTimer()
    }

    private func armShowTimer() {
        showTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + settings.showDelay)
        timer.setEventHandler { [weak self] in
            self?.handleShowDelayFired()
        }
        timer.resume()
        showTimer = timer
    }

    private func handleShowDelayFired() {
        guard state == .pending else { return }
        showTimer = nil
        guard tracker.activeCount > 0, !skippedThisWait else {
            enterIdle()
            return
        }
        switch settings.mode {
        case .auto:
            beginShowing(openedBy: .auto, at: now())
        case .ask:
            state = .offering
            stats.append(.chip(action: .offered))
            presentChip()
        case .off:
            // Defensive — mode flipped mid-flight.
            enterIdle()
        }
    }

    private func beginShowing(openedBy: ContentOpenedBy, at t: Date) {
        state = .showing
        showingStartedAt = t
        showOpenedBy = openedBy
        isManuallyPinned = (openedBy == .cmd || openedBy == .http || openedBy == .menu)
        presentWindow()
    }

    private func handleStop(sid: String?) -> String {
        let known = sid.map { tracker.sessions.keys.contains($0) } ?? (tracker.anonCount > 0)
        let becameEmpty = tracker.stop(sid: sid)
        // `known=false` is the tell for a stop that closed nothing it owned —
        // a duplicate (both Stop and SessionEnd fire /stop), or an id the
        // daemon never saw a start for. Harmless with real ids, since an
        // unknown id is dropped; worth seeing in the log because with
        // anonymous sessions the same duplicate *does* decrement the count.
        cmLog("session stop sid=\(sid ?? "<anon>") known=\(known) active=\(tracker.activeCount)\(becameEmpty ? " (→0, closing)" : "")")
        if becameEmpty {
            handleWaitEnded(closedBy: .stop, suppressSnapBack: false)
        }
        return "session stopped (active=\(tracker.activeCount))"
    }

    /// Signal-driven shutdown (SIGTERM/SIGHUP/SIGINT). Closes any open
    /// content episode so the log and the stats agree with what the user just
    /// saw happen — before this, a killed daemon took its window off screen
    /// with no `content` event and no log line, which is exactly the
    /// "the window closed by itself and nothing recorded it" case.
    func shutdown(reason: String) {
        queue.sync {
            cmLog("shutting down: \(reason) (state=\(state) active=\(tracker.activeCount))")
            showTimer?.cancel()
            showTimer = nil
            if state == .showing || state == .alerting {
                pauseContent()
                logContentEnd(closedBy: .quit, at: now())
            }
        }
    }

    /// Shared "count reached 0" driver, called from both `/stop` and the
    /// watchdog. Covers PENDING/OFFERING/SHOWING/ALERTING→IDLE in one place.
    private func handleWaitEnded(closedBy: ContentClosedBy, suppressSnapBack: Bool) {
        let t = now()
        showTimer?.cancel()
        showTimer = nil

        var didCloseContent = false

        switch state {
        case .pending:
            enterIdle()
        case .offering:
            dismissChip()
            enterIdle()
        case .showing, .alerting:
            if closedBy == .stop && isManuallyPinned {
                // Manual override (see `isManuallyPinned`'s doc comment) —
                // an incidental /stop from whatever session happened to
                // trigger the manual show must not close it. Leave state,
                // showingStartedAt/showOpenedBy, and capturedFrontmostApp
                // untouched; the episode continues until an explicit
                // /claude-maxx off or the watchdog closes it instead.
                break
            }
            pauseContent()
            hideWindowAction()
            logContentEnd(closedBy: closedBy, at: t)
            if settings.snapBack, !suppressSnapBack, let app = capturedFrontmostApp {
                app.activate(options: [])
            }
            enterIdle()
            didCloseContent = true
        case .idle:
            break // Post-Skip "IDLE*" case: count reached 0 with nothing visible.
        }

        if let start = waitStartedAt {
            stats.append(.wait(seconds: t.timeIntervalSince(start), at: t))
        }
        waitStartedAt = nil
        skippedThisWait = false
        if didCloseContent {
            isManuallyPinned = false
            capturedFrontmostApp = nil
            showingStartedAt = nil
            showOpenedBy = nil
        }
    }

    private func logContentEnd(closedBy: ContentClosedBy, at t: Date) {
        guard let start = showingStartedAt else { return }
        stats.append(.content(
            seconds: t.timeIntervalSince(start),
            openedBy: showOpenedBy ?? .http,
            closedBy: closedBy,
            channel: settings.channel,
            at: t
        ))
    }

    private func handleAttention() -> String {
        if state == .showing {
            pauseContent()
            bounceAttention()
            state = .alerting
        }
        // Unconditional log per §9.2's emit point; the state transition only
        // fires from the SHOWING row per §6's table — ALERTING while already
        // ALERTING is an idempotent no-op.
        stats.append(.attention())
        return "attention received"
    }

    private func handleCommandOff() {
        showTimer?.cancel()
        showTimer = nil
        switch state {
        case .pending:
            enterIdle()
        case .offering:
            dismissChip()
            enterIdle()
        case .showing, .alerting:
            // Unconditional, unlike handleWaitEnded's /stop path — an
            // explicit /claude-maxx off always closes, pinned or not; it's
            // the one thing that's supposed to end a manually-pinned episode.
            pauseContent()
            hideWindowAction()
            logContentEnd(closedBy: .cmd, at: now())
            enterIdle()
        case .idle:
            break
        }
        isManuallyPinned = false
        showingStartedAt = nil
        showOpenedBy = nil
    }

    private func handleShowNow(openedBy: ContentOpenedBy) {
        switch state {
        case .showing, .alerting:
            // Already visible — but if a manual override (menu/cmd/http)
            // arrives while an *automatic* (.auto/.chip) episode is already
            // showing, upgrade it to pinned. Without this, a user running
            // /claude-maxx now/setup to explicitly "take over" an
            // already-open window would still have it close on the
            // originating session's next /stop, since nothing here
            // otherwise touches isManuallyPinned at all.
            if openedBy == .cmd || openedBy == .http || openedBy == .menu {
                isManuallyPinned = true
            }
        case .offering:
            dismissChip()
            beginShowing(openedBy: openedBy, at: now())
        case .idle, .pending:
            showTimer?.cancel()
            showTimer = nil
            beginShowing(openedBy: openedBy, at: now())
        }
    }

    /// ALERTING re-points too, and resolves the alert while doing it.
    ///
    /// The window is on screen in both states, so gating on `.showing` alone
    /// made the menu's channel picker silently do nothing whenever a
    /// notification had landed first — reported as "it's not changing the
    /// window". But widening the guard without clearing the alert would leave
    /// fresh content playing while `state` still read `.alerting`, so the next
    /// `/attention` would no-op against it and never pause. Picking a channel
    /// *is* user interaction, so the alert clears with it.
    private func handleRefreshIfShowing() {
        cmLog("refreshIfShowing: state=\(state) channel=\(settings.channel)")
        switch state {
        case .showing:
            presentWindow()
        case .alerting:
            state = .showing
            presentWindow()
        case .idle, .pending, .offering:
            break
        }
    }

    private func handleSuppressCurrentWait() {
        switch state {
        case .pending:
            showTimer?.cancel()
            showTimer = nil
            skippedThisWait = true
            enterIdle()
        case .offering:
            // No `.chip(action: .skip)` stats event — the user didn't skip;
            // their own command turn is just declining to self-present.
            dismissChip()
            skippedThisWait = true
            enterIdle()
        case .idle, .showing, .alerting:
            break
        }
    }

    private func handleChipSelect(channelID: String) {
        guard state == .offering else { return }
        dismissChip()
        settings.channel = channelID          // persists via SettingsStore, matches menu's own persistence path
        stats.append(.chip(action: .watch))    // still the "watch" outcome — no new ChipAction case needed
        beginShowing(openedBy: .chip, at: now())
    }

    private func handleChipSkip() {
        guard state == .offering else { return }
        dismissChip()
        stats.append(.chip(action: .skip))
        skippedThisWait = true
        enterIdle()
    }

    private func handleUserInteraction() {
        guard state == .alerting else { return }
        state = .showing
    }

    // MARK: Watchdog

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
        timer.setEventHandler { [weak self] in
            self?.handleWatchdogFired()
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func handleWatchdogFired() {
        let cutoff = now().addingTimeInterval(-watchdogTimeout)
        if tracker.expireStale(before: cutoff) {
            handleWaitEnded(closedBy: .watchdog, suppressSnapBack: true)
        }
    }

    // MARK: Presentation actions
    //
    // All four hop to main thread like presentChip()/dismissChip() below —
    // these handlers run on `queue` (a background serial queue), and the
    // lazy `feedPresenter`/`chipPresenter` must first-materialize on the
    // main thread since AppKit view/window construction off the main
    // thread is undefined behavior.

    private func presentChip() {
        // `chipPresenter` is a lazy var whose first access constructs a real
        // ChipPanel (NSPanel + AppKit views). presentChip()/dismissChip() run
        // on `queue` (a background serial queue), so that first materialization
        // must be pushed onto the main thread explicitly — AppKit view/window
        // construction off the main thread is undefined behavior. `.present()`
        // itself also main-hops internally, but only *after* the lazy var
        // already exists, which is too late to protect the construction site.
        DispatchQueue.main.async { [weak self] in
            self?.chipPresenter.present()
        }
    }

    private func dismissChip() {
        DispatchQueue.main.async { [weak self] in
            self?.chipPresenter.dismiss()
        }
    }

    private func presentWindow() {
        // Resolve `settings.channel` (persisted cm.channel, mutated by the
        // chip picker and the menu's channel selector) through the channel
        // registry (§12 M2 task 11). Falls back to the first registered
        // channel if the stored id doesn't match anything current (e.g. a
        // stale value from a channel that no longer exists).
        let channel = ChannelRegistry.channel(withID: settings.channel) ?? ChannelRegistry.all.first
        DispatchQueue.main.async { [weak self] in
            self?.feedPresenter.show(channel: channel)
        }
    }

    private func hideWindowAction() {
        DispatchQueue.main.async { [weak self] in
            self?.feedPresenter.hide()
        }
    }

    private func pauseContent() {
        DispatchQueue.main.async { [weak self] in
            self?.feedPresenter.pause()
        }
    }

    private func bounceAttention() {
        DispatchQueue.main.async { [weak self] in
            self?.feedPresenter.attention()
        }
    }
}
