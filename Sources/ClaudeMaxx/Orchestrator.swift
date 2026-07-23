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

    /// Re-resolves `settings.channel` and re-points the shared webview while
    /// a content episode is already open — the fix for Menu's channel picker
    /// while the setup/login window is up (multiple platforms to sign into
    /// in one open episode). A no-op outside SHOWING, including ALERTING:
    /// re-presenting fresh content there would leave `state` at `.alerting`
    /// (still "paused, awaiting attention") while the new channel is actually
    /// unpaused and playing, and `handleAttention`'s `state == .showing`
    /// guard (§6) would then no-op a genuinely new `/attention` until the
    /// user interacts — so channel switching during an attention alert stays
    /// a persist-only no-op, same as while idle. Deliberately does not touch
    /// state/timers/stats otherwise — it is not a new content episode, just
    /// a live re-point of the current one.
    func switchChannelIfShowing() {
        queue.sync { handleSwitchChannelIfShowing() }
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
            enterIdle()
        case .offering:
            dismissChip()
            enterIdle()
        case .showing, .alerting:
            pauseContent()
            hideWindowAction()
            logContentEnd(closedBy: closedBy, at: t)
            if settings.snapBack, !suppressSnapBack, let app = capturedFrontmostApp {
                app.activate(options: [])
            }
            enterIdle()
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
            enterIdle()
        case .offering:
            dismissChip()
            enterIdle()
        case .showing, .alerting:
            pauseContent()
            hideWindowAction()
            logContentEnd(closedBy: .cmd, at: now())
            enterIdle()
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

    private func handleSwitchChannelIfShowing() {
        guard state == .showing else { return }
        presentWindow()
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
