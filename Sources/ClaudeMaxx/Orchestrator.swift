import AppKit
import Foundation

// MARK: - PresentationState (SPEC §6)

/// SPEC §6: PENDING = debounce armed, OFFERING = chip visible, SHOWING = window
/// visible, ALERTING = visible, paused, attention requested.
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

/// Lets Menu refresh its stats item on IDLE transitions without polling (§9.3).
/// Posted on Orchestrator's background queue — observers must hop to main.
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

    /// Lazy so init never touches AppKit unless a chip is shown — that is what
    /// keeps a default-constructed Orchestrator safe to build in tests.
    private lazy var chipPresenter: ChipPresenting = {
        let presenter = chipPresenterFactory()
        presenter.onSelect = { [weak self] channelID in self?.chipSelect(channelID: channelID) }
        presenter.onSkip = { [weak self] in self?.chipSkip() }
        return presenter
    }()

    /// Lazy for the same reason; no callbacks to wire.
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
    /// True for a manual override (`.cmd`, `.http`, `.menu`), false for the
    /// automatic per-prompt flow. A pinned episode ignores `/stop` and closes only
    /// on `/claude-maxx off` or the watchdog — see CLAUDE.md.
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

    /// Re-points an already-open episode at the current settings: the channel
    /// picker mid-login, and `scroll on|off` taking effect now rather than on the
    /// next open. Not a new episode, so it touches no state, timers or stats.
    ///
    /// A no-op outside SHOWING, ALERTING included: re-presenting there would leave
    /// `state == .alerting` while the new channel plays unpaused, and
    /// `handleAttention`'s guard would then swallow a genuinely new `/attention`.
    func refreshIfShowing() {
        queue.sync { handleRefreshIfShowing() }
    }

    /// Cancels PENDING or dismisses OFFERING without touching the session count,
    /// so a settings command doesn't flash a window for its own turn (CLAUDE.md).
    /// SHOWING/ALERTING are left alone — an episode already on screen must not be
    /// killed by an incidental settings command.
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

    /// OFFERING is not window-visible: `/status` reports `window=hidden` while a
    /// chip is up.
    var isWindowVisible: Bool {
        queue.sync { state == .showing || state == .alerting }
    }

    /// Surfaced in `/status` so "why isn't the window closing?" is answerable
    /// without reading this file.
    var isWindowPinned: Bool {
        queue.sync { (state == .showing || state == .alerting) && isManuallyPinned }
    }

    // MARK: Private handlers (assume already on `queue`)

    /// The single signal Menu observes for IDLE transitions (§9.3). Posting on
    /// already-idle paths too is harmless — Menu's handler is idempotent.
    private func enterIdle() {
        state = .idle
        NotificationCenter.default.post(name: .claudeMaxxDidBecomeIdle, object: nil)
    }

    /// `suppress` marks a turn that must never present content, decided at submit
    /// time because `/cmd` arrives too late to help (CLAUDE.md). Confined to the
    /// 0→1 transition so a command in one session cannot cancel a window another
    /// session's prompt owns.
    private func handleStart(sid: String?, suppress: Bool = false) -> String {
        let t = now()
        let becameActive = tracker.start(sid: sid, now: t)
        // Without this line "the window closed while I was mid-prompt" is
        // unanswerable: a close is legitimate only if the count truly reached 0.
        cmLog("session start sid=\(sid ?? "<anon>") active=\(tracker.activeCount)\(becameActive ? " (0→1)" : "")\(suppress ? " suppressed" : "")")
        if becameActive {
            waitStartedAt = t
            skippedThisWait = suppress
            // Genuine idle starts only. Clobbering an already-showing manual
            // window to .pending made the machine forget it was in an episode, so
            // the eventual /stop took the chip path and the window never closed.
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
        // `known=false` means this stop closed nothing it owned — a duplicate (both
        // Stop and SessionEnd fire /stop) or an unseen id. Harmless for real ids,
        // but for anonymous sessions the duplicate *does* decrement.
        cmLog("session stop sid=\(sid ?? "<anon>") known=\(known) active=\(tracker.activeCount)\(becameEmpty ? " (→0, closing)" : "")")
        if becameEmpty {
            handleWaitEnded(closedBy: .stop, suppressSnapBack: false)
        }
        return "session stopped (active=\(tracker.activeCount))"
    }

    /// Closes any open episode so stats and log agree with what the user saw. A
    /// killed daemon otherwise takes its window off screen with no record — the
    /// "window closed by itself and nothing recorded it" case.
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
                // Manual override: an incidental /stop must not close it. Leave
                // everything untouched and let /claude-maxx off or the watchdog end
                // the episode (see `isManuallyPinned`).
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
            // Unlike the /stop path: an explicit off always closes, pinned or not.
            pauseContent()
            hideWindowAction()
            logContentEnd(closedBy: .cmd, at: now())
            if settings.snapBack, let app = capturedFrontmostApp {
                app.activate(options: [])
            }
            enterIdle()
        case .idle:
            break
        }
        isManuallyPinned = false
        capturedFrontmostApp = nil
        showingStartedAt = nil
        showOpenedBy = nil
    }

    private func handleShowNow(openedBy: ContentOpenedBy) {
        switch state {
        case .showing, .alerting:
            // A manual override arriving over an automatic episode upgrades it to
            // pinned. Without this, "take over this window" still let the
            // originating session's next /stop close it.
            if openedBy == .cmd || openedBy == .http || openedBy == .menu {
                isManuallyPinned = true
            }
        case .offering:
            dismissChip()
            beginShowing(openedBy: openedBy, at: now())
        case .idle, .pending:
            // Only from .idle: .pending already captured this at enterPending, and
            // overwriting it here would lose the app that was frontmost when the
            // wait started. Without this, snap-back on a manual hide/off (snapBack
            // defaults true) silently never fires — see CLAUDE.md.
            if state == .idle {
                capturedFrontmostApp = NSWorkspace.shared.frontmostApplication
            }
            showTimer?.cancel()
            showTimer = nil
            beginShowing(openedBy: openedBy, at: now())
        }
    }

    /// ALERTING re-points too, and resolves the alert while doing it. Gating on
    /// `.showing` alone made the channel picker silently do nothing once a
    /// notification had landed ("it's not changing the window"), but widening the
    /// guard without clearing the alert would leave the next `/attention` unable to
    /// pause. Picking a channel *is* user interaction, so the alert clears with it.
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
    // All of these main-hop. The handlers run on `queue`, and the lazy
    // `feedPresenter`/`chipPresenter` must *first-materialize* on main: AppKit
    // construction off main is undefined behavior, and the presenters' own
    // internal main-hops happen too late to protect their construction site.

    private func presentChip() {
        // Main-hopped for the reason given above the MARK.
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
        // Falls back to the first registered channel when the persisted id no
        // longer matches one — e.g. a channel that has since been removed.
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
