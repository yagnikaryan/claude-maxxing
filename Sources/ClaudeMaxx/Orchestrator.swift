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

    private let queue = DispatchQueue(label: "com.claudemaxx.orchestrator")

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

    /// The showDelay debounce, one-shot.
    private var showTimer: DispatchSourceTimer?
    /// Repeating watchdog, started in init.
    private var watchdogTimer: DispatchSourceTimer?

    init(
        settings: SettingsStore = .shared,
        stats: StatsStore = .shared,
        watchdogTimeout: TimeInterval = 1800,
        watchdogInterval: TimeInterval = 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.stats = stats
        self.watchdogTimeout = watchdogTimeout
        self.watchdogInterval = watchdogInterval
        self.now = now
        startWatchdog()
    }

    deinit {
        showTimer?.cancel()
        watchdogTimer?.cancel()
    }

    // MARK: Public API

    func start(sid: String?) -> String {
        queue.sync { handleStart(sid: sid) }
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

    /// Future ChipPanel hook — not wired from HookServer yet.
    func chipWatch() {
        queue.sync { handleChipWatch() }
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

    // MARK: Private handlers (assume already on `queue`)

    private func handleStart(sid: String?) -> String {
        let t = now()
        let becameActive = tracker.start(sid: sid, now: t)
        if becameActive {
            waitStartedAt = t
            skippedThisWait = false
            if settings.mode != .off {
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
            state = .idle
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
            state = .idle
        }
    }

    private func beginShowing(openedBy: ContentOpenedBy, at t: Date) {
        state = .showing
        showingStartedAt = t
        showOpenedBy = openedBy
        presentWindow()
    }

    private func handleStop(sid: String?) -> String {
        let becameEmpty = tracker.stop(sid: sid)
        if becameEmpty {
            handleWaitEnded(closedBy: .stop, suppressSnapBack: false)
        }
        return "session stopped (active=\(tracker.activeCount))"
    }

    /// Shared "count reached 0" driver, called from both `/stop` and the
    /// watchdog. Covers PENDING/OFFERING/SHOWING/ALERTING→IDLE in one place.
    private func handleWaitEnded(closedBy: ContentClosedBy, suppressSnapBack: Bool) {
        let t = now()
        showTimer?.cancel()
        showTimer = nil

        switch state {
        case .pending:
            state = .idle
        case .offering:
            dismissChip()
            state = .idle
        case .showing, .alerting:
            pauseContent()
            hideWindowAction()
            logContentEnd(closedBy: closedBy, at: t)
            if settings.snapBack, !suppressSnapBack, let app = capturedFrontmostApp {
                app.activate(options: [])
            }
            state = .idle
        case .idle:
            break // Post-Skip "IDLE*" case: count reached 0 with nothing visible.
        }

        if let start = waitStartedAt {
            stats.append(.wait(seconds: t.timeIntervalSince(start), at: t))
        }
        waitStartedAt = nil
        skippedThisWait = false
        capturedFrontmostApp = nil
        showingStartedAt = nil
        showOpenedBy = nil
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
            state = .idle
        case .offering:
            dismissChip()
            state = .idle
        case .showing, .alerting:
            pauseContent()
            hideWindowAction()
            logContentEnd(closedBy: .cmd, at: now())
            state = .idle
        case .idle:
            break
        }
        showingStartedAt = nil
        showOpenedBy = nil
    }

    private func handleShowNow(openedBy: ContentOpenedBy) {
        switch state {
        case .showing, .alerting:
            break // Already visible.
        case .offering:
            dismissChip()
            beginShowing(openedBy: openedBy, at: now())
        case .idle, .pending:
            showTimer?.cancel()
            showTimer = nil
            beginShowing(openedBy: openedBy, at: now())
        }
    }

    private func handleChipWatch() {
        guard state == .offering else { return }
        dismissChip()
        stats.append(.chip(action: .watch))
        beginShowing(openedBy: .chip, at: now())
    }

    private func handleChipSkip() {
        guard state == .offering else { return }
        dismissChip()
        stats.append(.chip(action: .skip))
        skippedThisWait = true
        state = .idle
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

    // MARK: Presentation-action stubs
    //
    // Real bodies land once ChipPanel/FeedPanel exist. Kept as real,
    // no-throw, side-effect-free stubs so the state machine's control flow
    // around them is fully exercised now.

    private func presentChip() {
        log("TODO(Panels): show ChipPanel (channel=\(settings.channel))")
    }

    private func dismissChip() {
        log("TODO(Panels): dismiss ChipPanel")
    }

    private func presentWindow() {
        log("TODO(Panels): show FeedPanel (channel=\(settings.channel))")
    }

    private func hideWindowAction() {
        log("TODO(Panels): hide FeedPanel")
    }

    private func pauseContent() {
        log("TODO(Panels): pause content")
    }

    private func bounceAttention() {
        log("TODO(Panels): bounce attention")
    }

    private func log(_ message: String) {
        FileHandle.standardError.write("Orchestrator: \(message)\n".data(using: .utf8)!)
    }
}
