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

    func show(channel: ContentChannel?) {
        shownChannelIDs.append(channel?.id)
    }

    func hide() {
        hideCount += 1
    }

    func pause() {}
    func attention() {}
}

final class OrchestratorTests: XCTestCase {

    /// `Orchestrator.presentWindow()` hops to `DispatchQueue.main.async`
    /// before calling into `FeedPresenting` (AppKit calls must land on
    /// main) — briefly spin the run loop so that queued block actually runs
    /// before assertions inspect the spy.
    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func makeOrchestrator(spy: SpyFeedPresenter, settings: SettingsStore) -> Orchestrator {
        let statsFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jsonl")
        return Orchestrator(
            settings: settings,
            stats: StatsStore(fileURL: statsFileURL),
            feedPresenterFactory: { spy }
        )
    }

    /// The bug this covers: picking a second channel from the menu while the
    /// window is already open used to be silently dropped (`handleShowNow`'s
    /// `.showing, .alerting: break` case never re-presented), so a user could
    /// only ever log into whichever channel happened to be active on first
    /// show.
    func testSwitchChannelIfShowingRePresentsWithNewChannelWhileWindowIsOpen() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.channel = "shorts"
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        orchestrator.showNow(openedBy: .menu)
        drainMainQueue()
        XCTAssertEqual(spy.shownChannelIDs, ["shorts"])

        settings.channel = "xfeed"
        orchestrator.switchChannelIfShowing()
        drainMainQueue()
        XCTAssertEqual(spy.shownChannelIDs, ["shorts", "xfeed"])
    }

    /// Picking a channel while nothing is showing must remain a pure
    /// setting-persist with no presentation side effect (existing behavior,
    /// unchanged) — the fix only adds a live re-point while already open.
    func testSwitchChannelIfShowingIsNoOpWhileIdle() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        settings.channel = "reading"
        orchestrator.switchChannelIfShowing()

        XCTAssertTrue(spy.shownChannelIDs.isEmpty)
    }

    /// Channel switching while ALERTING (window up, paused, awaiting
    /// attention) must stay a no-op, same as idle — re-presenting fresh
    /// content there would leave `state` at `.alerting` while the new
    /// channel is actually unpaused, and a genuinely new `/attention` would
    /// then no-op against it (`handleAttention`'s `state == .showing` guard).
    /// Scoping the live-switch fix to SHOWING only avoids that regression.
    func testSwitchChannelIfShowingIsNoOpWhileAlerting() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.channel = "shorts"
        let spy = SpyFeedPresenter()
        let orchestrator = makeOrchestrator(spy: spy, settings: settings)

        orchestrator.showNow(openedBy: .menu)
        drainMainQueue()
        _ = orchestrator.attention()
        XCTAssertEqual(spy.shownChannelIDs, ["shorts"]) // sanity: now alerting, not re-shown

        settings.channel = "xfeed"
        orchestrator.switchChannelIfShowing()
        drainMainQueue()

        XCTAssertEqual(spy.shownChannelIDs, ["shorts"]) // unchanged — no-op while alerting
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

    /// Regression test for the "window never closes" bug: opening the
    /// window manually (Show Window Now / /claude-maxx setup) with zero
    /// sessions, then starting a real prompt afterward, used to clobber
    /// `state` from .showing back to .pending inside handleStart — the
    /// window stayed visibly open, but the state machine no longer knew it
    /// was in a content episode. When the prompt's `/stop` later drove the
    /// session count back to 0, handleWaitEnded saw .pending/.offering
    /// instead of .showing and never called hide() — the window would sit
    /// there forever. It must instead stay .showing straight through, and
    /// close normally once the real session ends.
    func testWindowOpenedManuallyThenAPromptStartsAndEndsStillCloses() {
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

        XCTAssertFalse(orchestrator.isWindowVisible)
        XCTAssertEqual(spy.hideCount, 1, "the window must actually be hidden once the real session ends")
    }
}
