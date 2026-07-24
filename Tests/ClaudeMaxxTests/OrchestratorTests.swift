import XCTest
@testable import ClaudeMaxx

/// Records every call instead of touching AppKit — lets Orchestrator's
/// presentation logic be driven headlessly, same pattern as
/// `feedPresenterFactory`'s injection point is meant for. Internal (not
/// file-private) so HookServerTests can reuse it instead of exercising a
/// real `FeedPanel`/`WKWebView` through the default `Router()`.
final class SpyFeedPresenter: FeedPresenting {
    private(set) var shownChannelIDs: [String?] = []
    private(set) var hideCount = 0
    private(set) var pauseCount = 0

    func show(channel: ContentChannel?) {
        shownChannelIDs.append(channel?.id)
    }

    func hide() {
        hideCount += 1
    }

    func pause() { pauseCount += 1 }
    func attention() {}
}

/// Chip-side twin of `SpyFeedPresenter`, for driving the ask-mode
/// OFFERING flow headlessly.
final class SpyChipPresenter: ChipPresenting {
    var onSelect: ((String) -> Void)?
    var onSkip: (() -> Void)?
    private(set) var presentCount = 0
    private(set) var dismissCount = 0

    func present() { presentCount += 1 }
    func dismiss() { dismissCount += 1 }
}

final class OrchestratorTests: XCTestCase {

    /// `Orchestrator.presentWindow()` hops to `DispatchQueue.main.async`
    /// before calling into `FeedPresenting` (AppKit calls must land on
    /// main) — briefly spin the run loop so that queued block actually runs
    /// before assertions inspect the spy.
    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func makeOrchestrator(
        spy: SpyFeedPresenter,
        settings: SettingsStore,
        chipSpy: SpyChipPresenter = SpyChipPresenter()
    ) -> Orchestrator {
        let statsFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jsonl")
        return Orchestrator(
            settings: settings,
            stats: StatsStore(fileURL: statsFileURL),
            chipPresenterFactory: { chipSpy },
            feedPresenterFactory: { spy }
        )
    }

    /// The bug this covers: picking a second channel from the menu while the
    /// window is already open used to be silently dropped (`handleShowNow`'s
    /// `.showing, .alerting: break` case never re-presented), so a user could
    /// only ever log into whichever channel happened to be active on first
    /// show.
    func testRefreshIfShowingRePresentsWithNewChannelWhileWindowIsOpen() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.channel = "shorts"
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        orchestrator.showNow(openedBy: .menu)
        drainMainQueue()
        XCTAssertEqual(spy.shownChannelIDs, ["shorts"])

        settings.channel = "xfeed"
        orchestrator.refreshIfShowing()
        drainMainQueue()
        XCTAssertEqual(spy.shownChannelIDs, ["shorts", "xfeed"])
    }

    /// Picking a channel while nothing is showing must remain a pure
    /// setting-persist with no presentation side effect (existing behavior,
    /// unchanged) — the fix only adds a live re-point while already open.
    func testRefreshIfShowingIsNoOpWhileIdle() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        settings.channel = "reading"
        orchestrator.refreshIfShowing()

        XCTAssertTrue(spy.shownChannelIDs.isEmpty)
    }

    /// Channel switching while ALERTING (window up, paused after a
    /// notification) must re-point the window, not silently do nothing.
    /// This previously no-op'd, which read as "changing the platform in the
    /// menu doesn't change the window" — `/attention` fires on every Claude
    /// Code notification, so ALERTING is a common state to be picking a
    /// channel from.
    ///
    /// The no-op existed to avoid leaving `state` at `.alerting` while fresh
    /// unpaused content played, which would make the next `/attention`
    /// no-op against it. Resolving the alert on re-point is what makes the
    /// switch safe, so both halves are asserted here.
    func testRefreshWhileAlertingRepointsAndResolvesTheAlert() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.channel = "shorts"
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        orchestrator.showNow(openedBy: .menu)
        drainMainQueue()
        _ = orchestrator.attention()
        XCTAssertEqual(spy.shownChannelIDs, ["shorts"]) // sanity: now alerting

        settings.channel = "xfeed"
        orchestrator.refreshIfShowing()
        drainMainQueue()
        XCTAssertEqual(spy.shownChannelIDs, ["shorts", "xfeed"], "the open window must follow the menu")

        // The alert must be resolved, or this attention would no-op and the
        // newly-playing channel would keep going with audio after a
        // notification — the exact regression the old no-op protected.
        let pausesBefore = spy.pauseCount
        _ = orchestrator.attention()
        drainMainQueue()
        XCTAssertEqual(spy.pauseCount, pausesBefore + 1, "a notification must still pause the switched-to channel")
    }

    /// `showNow` (the setup/debug entry point, §8.1/§14) must work with zero
    /// active sessions and must not require a chip/prompt in flight.
    func testShowNowWorksWithNoActiveSessions() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        XCTAssertEqual(orchestrator.activeSessionCount, 0)
        orchestrator.showNow(openedBy: .menu)
        drainMainQueue()

        XCTAssertTrue(orchestrator.isWindowVisible)
        XCTAssertEqual(spy.shownChannelIDs, [settings.channel])
    }

    /// Regression test for the original "window never closes" bug: opening
    /// the window manually (Show Window Now / /claude-maxx setup) with zero
    /// sessions, then a real prompt starting afterward, used to clobber
    /// `state` from .showing back to .pending inside handleStart even though
    /// the window was still visibly open — the `state == .idle` guard added
    /// to `handleStart` prevents that clobbering.
    ///
    /// Updated expectation (superseding this test's original one): a
    /// manually-opened episode is *pinned* — decoupled from any particular
    /// session's lifecycle — so a real prompt merely running-and-finishing
    /// while it's open must NOT close it either; only an explicit
    /// /claude-maxx off does that (see the pinning tests below). What this
    /// test actually still guards against: without the .idle guard, that
    /// intervening real prompt's 0→1 start would re-enter PENDING and, if it
    /// ever reached beginShowing again (e.g. mode=auto), reset
    /// `isManuallyPinned` back to false purely because an unrelated session
    /// happened to start — silently un-pinning a window the user explicitly
    /// asked to keep open.
    func testWindowOpenedManuallyThenAPromptStartsAndEndsStaysPinnedOpen() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        orchestrator.showNow(openedBy: .menu)
        drainMainQueue()
        XCTAssertTrue(orchestrator.isWindowVisible)

        _ = orchestrator.start(sid: "a")
        XCTAssertTrue(
            orchestrator.isWindowVisible,
            "a prompt starting after a manual show must not knock the window out of SHOWING"
        )

        _ = orchestrator.stop(sid: "a")
        drainMainQueue()

        XCTAssertTrue(
            orchestrator.isWindowVisible,
            "a manually-pinned window must not close just because an unrelated real prompt finished"
        )
        XCTAssertEqual(spy.hideCount, 0)
    }

    /// Regression test for "/claude-maxx setup opens a window, but it closes
    /// as soon as the prompt completes". `/claude-maxx setup`/`now` is
    /// itself submitted as a Claude Code prompt, so its own
    /// UserPromptSubmit/Stop hooks fire around that same turn: /start(sid)
    /// registers the session (→ PENDING, since mode≠off) *before* the
    /// embedded curl even runs, then showNow(openedBy: .cmd) fires from
    /// handling /cmd?arg=setup while state is still .pending, then that same
    /// sid's Stop fires almost immediately once the trivial curl-and-echo
    /// turn ends. Without the manual-pin fix, that /stop would close the
    /// window the command just opened for itself — defeating the entire
    /// point of "open it so I can log in".
    func testClaudeMaxxSetupWindowSurvivesItsOwnSlashCommandTurnEnding() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        // UserPromptSubmit fires first, per Claude Code's actual ordering.
        _ = orchestrator.start(sid: "setup-turn")
        // Then the command file's embedded curl hits /cmd?arg=setup.
        orchestrator.showNow(openedBy: .cmd)
        drainMainQueue()
        XCTAssertTrue(orchestrator.isWindowVisible)

        // The slash command's own turn ends almost instantly.
        _ = orchestrator.stop(sid: "setup-turn")
        drainMainQueue()

        XCTAssertTrue(
            orchestrator.isWindowVisible,
            "a manually-opened window must survive the /stop from the very session that opened it"
        )
        XCTAssertEqual(spy.hideCount, 0)
    }

    /// A manually-pinned episode is not stuck forever — /claude-maxx off
    /// must still close it.
    func testManuallyPinnedWindowStillClosesOnExplicitOff() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        _ = orchestrator.start(sid: "setup-turn")
        orchestrator.showNow(openedBy: .cmd)
        drainMainQueue()
        _ = orchestrator.stop(sid: "setup-turn")
        drainMainQueue()
        XCTAssertTrue(orchestrator.isWindowVisible) // sanity: still pinned open

        orchestrator.commandOff()
        drainMainQueue()

        XCTAssertFalse(orchestrator.isWindowVisible)
        XCTAssertEqual(spy.hideCount, 1)
    }

    /// The core automatic flow must be unaffected by the pinning fix: an
    /// .auto-opened episode (the real per-prompt feature, not a manual
    /// override) still closes normally when its own session's /stop fires.
    /// Drives the real showDelay timer (shortened so the test doesn't wait
    /// the real 4s default) rather than calling showNow directly, since
    /// .auto is only ever reached through handleShowDelayFired.
    func testAutoOpenedWindowStillClosesNormallyOnStop() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.mode = .auto
        settings.showDelay = 0.05
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        _ = orchestrator.start(sid: "a")
        Thread.sleep(forTimeInterval: 0.2)   // let the real showDelay timer fire
        drainMainQueue()
        XCTAssertTrue(orchestrator.isWindowVisible)

        _ = orchestrator.stop(sid: "a")
        drainMainQueue()

        XCTAssertFalse(orchestrator.isWindowVisible)
        XCTAssertEqual(spy.hideCount, 1)
    }

    /// Regression: `/claude-maxx off` opened the very window it was meant to
    /// close. Its own UserPromptSubmit armed the 4 s debounce, the window
    /// opened, and the command only landed 17 s later — the `/cmd` path can
    /// never be early enough, so the suppression has to happen at submit.
    func testSuppressedStartNeverPresentsForACommandsOwnTurn() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.mode = .auto
        settings.showDelay = 0.05
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        _ = orchestrator.start(sid: "cmd-turn", suppress: true)
        Thread.sleep(forTimeInterval: 0.2)   // well past showDelay
        drainMainQueue()

        XCTAssertFalse(orchestrator.isWindowVisible, "a /claude-maxx turn must not flash content")
        XCTAssertTrue(spy.shownChannelIDs.isEmpty)
    }

    /// The suppression must stay scoped to the wait it starts. A command typed
    /// in one session cannot cancel the window another session's prompt
    /// legitimately owns — only the 0→1 transition sets it.
    func testSuppressDoesNotCancelAnotherSessionsAlreadyRunningWait() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.mode = .auto
        settings.showDelay = 0.15
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        _ = orchestrator.start(sid: "worker")                      // real prompt, arms the debounce
        _ = orchestrator.start(sid: "cmd-turn", suppress: true)     // command in a second session
        Thread.sleep(forTimeInterval: 0.4)
        drainMainQueue()

        XCTAssertTrue(orchestrator.isWindowVisible, "the worker session's window must still open")
    }

    /// Regression test for a gap the pinning fix's own review caught:
    /// showNow's `.showing, .alerting: break` branch used to be a pure
    /// no-op when the window was already visible, so a user explicitly
    /// running /claude-maxx now/setup to "take over" an already-open
    /// *automatic* episode had no effect on isManuallyPinned — the window
    /// would still close on the *original* session's next /stop despite the
    /// user's explicit override.
    func testShowNowUpgradesToPinnedWhenAutoEpisodeAlreadyShowing() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.mode = .auto
        settings.showDelay = 0.05
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        _ = orchestrator.start(sid: "a")
        Thread.sleep(forTimeInterval: 0.2)
        drainMainQueue()
        XCTAssertTrue(orchestrator.isWindowVisible) // auto-opened, not pinned yet

        // A second, separate session runs /claude-maxx setup to explicitly grab control.
        _ = orchestrator.start(sid: "setup-turn")
        orchestrator.showNow(openedBy: .cmd)
        drainMainQueue()

        _ = orchestrator.stop(sid: "a") // original session ends; setup-turn still active
        drainMainQueue()
        XCTAssertTrue(orchestrator.isWindowVisible) // one active session remains regardless

        _ = orchestrator.stop(sid: "setup-turn") // count now reaches 0
        drainMainQueue()

        XCTAssertTrue(
            orchestrator.isWindowVisible,
            "explicitly running /claude-maxx now/setup on an already-open window must pin it"
        )
        XCTAssertEqual(spy.hideCount, 0)
    }

    /// A pinned episode still correctly enters ALERTING (handleAttention
    /// only checks state == .showing, pin-agnostic) and must survive an
    /// incidental /stop there too, same as while plain SHOWING.
    func testPinnedWindowSurvivesStopWhileAlerting() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        _ = orchestrator.start(sid: "setup-turn")
        orchestrator.showNow(openedBy: .cmd)
        drainMainQueue()
        _ = orchestrator.attention()
        drainMainQueue()

        _ = orchestrator.stop(sid: "setup-turn")
        drainMainQueue()

        XCTAssertTrue(
            orchestrator.isWindowVisible,
            "a pinned ALERTING episode must also survive an incidental /stop"
        )
        XCTAssertEqual(spy.hideCount, 0)
    }

    /// The watchdog is an unconditional safety net (SPEC §5) — it must
    /// close a pinned window too, unlike a plain /stop. Otherwise a
    /// forgotten "Show Window Now"/setup session whose sid never got its
    /// matching /stop (crash, force-quit) would pin the window open forever.
    func testWatchdogClosesAPinnedWindowRegardless() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let spy = SpyFeedPresenter()
        let statsFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jsonl")
        // timeout > interval, with enough separation that the immediate
        // sanity check below can't race the watchdog's first tick.
        let orchestrator = Orchestrator(
            settings: settings,
            stats: StatsStore(fileURL: statsFileURL),
            watchdogTimeout: 0.3,
            watchdogInterval: 0.05,
            feedPresenterFactory: { spy }
        )

        _ = orchestrator.start(sid: "orphaned")
        orchestrator.showNow(openedBy: .cmd)
        drainMainQueue()
        XCTAssertTrue(orchestrator.isWindowVisible)

        Thread.sleep(forTimeInterval: 0.6) // comfortably longer than timeout + one tick
        drainMainQueue()

        XCTAssertFalse(orchestrator.isWindowVisible, "the watchdog must close even a pinned window")
        XCTAssertEqual(spy.hideCount, 1)
    }

    // MARK: - suppressCurrentWait (the /claude-maxx command's own turn)

    /// A `/claude-maxx <settings arg>` turn arms the debounce via its own
    /// UserPromptSubmit and routinely outlives showDelay — suppression must
    /// cancel the pending show so the command turn never flashes the window.
    func testSuppressCurrentWaitCancelsPendingShow() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.mode = .auto
        settings.showDelay = 0.05
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        _ = orchestrator.start(sid: "cmd-turn")
        orchestrator.suppressCurrentWait()   // the embedded curl arrives before the timer fires
        Thread.sleep(forTimeInterval: 0.2)
        drainMainQueue()

        XCTAssertFalse(orchestrator.isWindowVisible)
        XCTAssertTrue(spy.shownChannelIDs.isEmpty)

        _ = orchestrator.stop(sid: "cmd-turn")   // turn ends cleanly, nothing to hide
        drainMainQueue()
        XCTAssertEqual(spy.hideCount, 0)
    }

    /// Same suppression in ask mode, arriving after the chip is already up
    /// (the timer fired before the curl): the chip must be dismissed.
    func testSuppressCurrentWaitDismissesOfferedChip() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.mode = .ask
        settings.showDelay = 0.05
        let spy = SpyFeedPresenter()
        let chipSpy = SpyChipPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings, chipSpy: chipSpy)

        _ = orchestrator.start(sid: "cmd-turn")
        Thread.sleep(forTimeInterval: 0.2)
        drainMainQueue()
        XCTAssertEqual(chipSpy.presentCount, 1)   // sanity: chip offered

        orchestrator.suppressCurrentWait()
        drainMainQueue()

        XCTAssertEqual(chipSpy.dismissCount, 1)
        XCTAssertFalse(orchestrator.isWindowVisible)
    }

    /// Suppression must never kill an episode already on screen — a pinned
    /// setup window (or a real prompt's content) survives an incidental
    /// settings command like /claude-maxx scroll on.
    func testSuppressCurrentWaitIsNoOpWhileShowing() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        orchestrator.showNow(openedBy: .cmd)
        drainMainQueue()
        XCTAssertTrue(orchestrator.isWindowVisible)

        orchestrator.suppressCurrentWait()
        drainMainQueue()

        XCTAssertTrue(orchestrator.isWindowVisible)
        XCTAssertEqual(spy.hideCount, 0)
    }

    // MARK: - Ask-mode chip flow (the core per-prompt loop)

    /// The full ask-mode cycle: prompt → chip → Watch → window → prompt ends
    /// → window closes. This is the flow the feature exists for; the pinning
    /// fix must never leak into it (openedBy .chip is not a manual pin).
    func testAskModeChipWatchOpensWindowAndStopCloses() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.mode = .ask
        settings.showDelay = 0.05
        let spy = SpyFeedPresenter()
        let chipSpy = SpyChipPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings, chipSpy: chipSpy)

        _ = orchestrator.start(sid: "a")
        Thread.sleep(forTimeInterval: 0.2)
        drainMainQueue()
        XCTAssertEqual(chipSpy.presentCount, 1)

        orchestrator.chipSelect(channelID: "shorts")
        drainMainQueue()
        XCTAssertTrue(orchestrator.isWindowVisible)
        XCTAssertFalse(orchestrator.isWindowPinned, "a chip-opened episode is not a manual pin")

        _ = orchestrator.stop(sid: "a")
        drainMainQueue()

        XCTAssertFalse(orchestrator.isWindowVisible, "the window must close when the prompt ends")
        XCTAssertEqual(spy.hideCount, 1)
    }
}
