import XCTest
@testable import ClaudeMaxx

final class HookServerTests: XCTestCase {

    // MARK: - HTTPRequestLine.parse

    func testParsesStandardGetRequestLine() {
        let request = HTTPRequestLine.parse("GET /start?sid=abc HTTP/1.1")
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/start")
        XCTAssertEqual(request?.query, ["sid": "abc"])
    }

    func testParsesPathWithNoQuery() {
        let request = HTTPRequestLine.parse("GET /status HTTP/1.1")
        XCTAssertEqual(request?.path, "/status")
        XCTAssertEqual(request?.query, [:])
    }

    func testParseReturnsNilForGarbage() {
        XCTAssertNil(HTTPRequestLine.parse(""))
        XCTAssertNil(HTTPRequestLine.parse("GET"))
    }

    // MARK: - Router

    private func makeRouter() -> Router {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let statsFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jsonl")
        let stats = StatsStore(fileURL: statsFileURL)
        // Termination is stubbed for every router here, not just the quit
        // tests: Router's default schedules a real `exit(0)` watchdog, so any
        // future test that happens to route `quit` through this helper would
        // take the test runner down with it.
        return Router(settings: settings, stats: stats, terminate: {})
    }

    func testRouterUnknownPathReturnsUnknownEndpoint() {
        let router = makeRouter()
        let request = HTTPRequestLine.parse("GET /nope HTTP/1.1")!
        XCTAssertEqual(router.route(request), "unknown endpoint")
    }

    func testRouterStartStopTracksActiveSessionsAndStatusReflectsThem() {
        let router = makeRouter()

        _ = router.route(HTTPRequestLine.parse("GET /start?sid=a HTTP/1.1")!)
        _ = router.route(HTTPRequestLine.parse("GET /start?sid=b HTTP/1.1")!)
        _ = router.route(HTTPRequestLine.parse("GET /stop?sid=a HTTP/1.1")!)

        let status = router.route(HTTPRequestLine.parse("GET /status HTTP/1.1")!)
        XCTAssertEqual(status, "v\(Version.current) mode=ask active_sessions=1 window=hidden auto_advance=true")
    }

    /// Regression: macOS ships no `jq`, so on a stock machine the hooks send
    /// `?sid=` with nothing after it. The query parser maps a valueless key to
    /// `""` rather than nil, so every session collided on one `sessions[""]`
    /// slot — two concurrent sessions counted as one, and the first prompt to
    /// finish closed the window on the other. Empty must count anonymously,
    /// which tracks concurrency correctly.
    func testEmptySessionIDsAreCountedIndependentlyNotCollapsedIntoOne() {
        let router = makeRouter()

        _ = router.route(HTTPRequestLine.parse("GET /start?sid= HTTP/1.1")!)
        _ = router.route(HTTPRequestLine.parse("GET /start?sid= HTTP/1.1")!)
        XCTAssertEqual(
            router.route(HTTPRequestLine.parse("GET /status HTTP/1.1")!),
            "v\(Version.current) mode=ask active_sessions=2 window=hidden auto_advance=true",
            "two jq-less sessions are two sessions"
        )

        _ = router.route(HTTPRequestLine.parse("GET /stop?sid= HTTP/1.1")!)
        XCTAssertEqual(
            router.route(HTTPRequestLine.parse("GET /status HTTP/1.1")!),
            "v\(Version.current) mode=ask active_sessions=1 window=hidden auto_advance=true",
            "one finishing must not close the window on the other"
        )
    }

    /// `quit` must answer before it exits. route(_:) runs before the response
    /// is written, so terminating synchronously would hand the client an empty
    /// body — and the wrapper reads "no response" as "daemon isn't running"
    /// and launches a fresh one, making quit silently relaunch.
    func testQuitAnswersBeforeTerminating() {
        var terminated = false
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let stats = StatsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jsonl"))
        let router = Router(settings: settings, stats: stats, terminate: { terminated = true })

        let response = router.route(HTTPRequestLine.parse("GET /cmd?arg=quit HTTP/1.1")!)

        XCTAssertTrue(response.hasPrefix("stopping the daemon"), "got: \(response)")
        XCTAssertTrue(terminated, "quit must actually request termination")
    }

    /// The bug this guards: `quit` answered "stopping the daemon" and the
    /// process kept running, logging no `applicationWillTerminate`, because
    /// `NSApp.terminate` is a request AppKit can defer or drop (a modal run
    /// loop swallows the queued call). The reply is the only thing a caller can
    /// check, so a requested exit is not enough — there must be a later stage
    /// that stops asking.
    ///
    /// Note what the sibling test above cannot catch: it asserts termination
    /// was *requested*, which was already true while the daemon survived.
    func testQuitTerminatorForcesExitAfterAppKitIsGivenItsChance() {
        var delays: [TimeInterval] = []
        var order: [String] = []
        var terminator = QuitTerminator(
            requestTermination: { order.append("appkit") },
            forceExit: { order.append("force") }
        )
        // Run each stage immediately, recording only when it was due — the
        // schedule is the thing under test, not the waiting.
        terminator.after = { delay, work in
            delays.append(delay)
            work()
        }

        terminator.schedule()

        XCTAssertEqual(order, ["appkit", "force"], "AppKit gets first refusal, then the watchdog")
        XCTAssertEqual(delays.count, 2, "both stages must be scheduled")
        XCTAssertGreaterThan(delays[0], 0, "stage 1 must wait for the response to be written")
        XCTAssertGreaterThan(delays[1], delays[0], "the watchdog must fire strictly after the request")
    }

    func testCmdModeGrammar() {
        let router = makeRouter()

        XCTAssertEqual(
            router.route(HTTPRequestLine.parse("GET /cmd?arg=auto HTTP/1.1")!),
            "claude-maxx mode set to auto"
        )
        XCTAssertEqual(
            router.route(HTTPRequestLine.parse("GET /cmd?arg=ask HTTP/1.1")!),
            "claude-maxx mode set to ask"
        )
        XCTAssertEqual(
            router.route(HTTPRequestLine.parse("GET /cmd?arg=off HTTP/1.1")!),
            "claude-maxx mode set to off"
        )
    }

    /// Builds its own Router (rather than `makeRouter()`) with an injected
    /// `SpyFeedPresenter` — `/cmd?arg=setup` calls `showNow`, which would
    /// otherwise materialize a real `FeedPanel`/`WKWebView` through
    /// `makeRouter()`'s default-constructed Orchestrator.
    func testCmdSetupOpensWindowAndPointsToMenuBar() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let statsFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jsonl")
        let stats = StatsStore(fileURL: statsFileURL)
        let spy = SpyFeedPresenter()
        let orchestrator = Orchestrator(settings: settings, stats: stats, feedPresenterFactory: { spy })
        let router = Router(settings: settings, stats: stats, orchestrator: orchestrator)

        let response = router.route(HTTPRequestLine.parse("GET /cmd?arg=setup HTTP/1.1")!)

        XCTAssertTrue(response.contains("opening window"))
        XCTAssertTrue(response.contains("CM menu bar"))
    }

    /// Builds a Router around injected spies — needed by every test whose
    /// /cmd path would otherwise materialize a real FeedPanel/WKWebView.
    private func makeSpyRouter() -> (Router, SpyFeedPresenter, SettingsStore) {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let statsFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jsonl")
        let stats = StatsStore(fileURL: statsFileURL)
        let spy = SpyFeedPresenter()
        let orchestrator = Orchestrator(
            settings: settings,
            stats: stats,
            chipPresenterFactory: { SpyChipPresenter() },
            feedPresenterFactory: { spy }
        )
        return (Router(settings: settings, stats: stats, orchestrator: orchestrator), spy, settings)
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// `--data-urlencode` (the command file's encoding) sends a space as
    /// `+`, which URLComponents does not decode — the Router must.
    func testCmdScrollOnAcceptsPlusEncodedSpace() {
        let (router, _, settings) = makeSpyRouter()
        settings.autoAdvance = false

        let response = router.route(HTTPRequestLine.parse("GET /cmd?arg=scroll+on HTTP/1.1")!)

        XCTAssertEqual(response, "auto-advance on")
        XCTAssertTrue(settings.autoAdvance)
    }

    /// `scroll on|off` while the window is open must re-present so the
    /// toggle applies to the live webview, not just the next show.
    func testCmdScrollToggleAppliesLiveWhileWindowOpen() {
        let (router, spy, settings) = makeSpyRouter()

        _ = router.route(HTTPRequestLine.parse("GET /cmd?arg=setup HTTP/1.1")!)
        drainMainQueue()
        XCTAssertEqual(spy.shownChannelIDs.count, 1)

        _ = router.route(HTTPRequestLine.parse("GET /cmd?arg=scroll%20off HTTP/1.1")!)
        drainMainQueue()

        XCTAssertFalse(settings.autoAdvance)
        XCTAssertEqual(spy.shownChannelIDs.count, 2, "the open window must be re-presented with the new flag")
    }

    /// `hide` closes a pinned setup window but leaves the mode alone —
    /// unlike `off`, which was the only way to close one before and
    /// silently disabled the whole feature as a side effect.
    func testCmdHideClosesPinnedWindowWithoutChangingMode() {
        let (router, spy, settings) = makeSpyRouter()
        settings.mode = .ask

        _ = router.route(HTTPRequestLine.parse("GET /cmd?arg=setup HTTP/1.1")!)
        drainMainQueue()

        let response = router.route(HTTPRequestLine.parse("GET /cmd?arg=hide HTTP/1.1")!)
        drainMainQueue()

        XCTAssertEqual(response, "window hidden — mode stays ask")
        XCTAssertEqual(spy.hideCount, 1)
        XCTAssertEqual(settings.mode, .ask)
    }

    /// A settings-only /cmd (scroll, stats, status, mode) arriving during
    /// its own turn's PENDING must cancel the pending show — the command
    /// turn itself must never flash the window.
    func testCmdSettingsArgSuppressesItsOwnTurnsPendingShow() {
        let (router, spy, settings) = makeSpyRouter()
        settings.mode = .auto
        settings.showDelay = 0.05

        _ = router.route(HTTPRequestLine.parse("GET /start?sid=cmd-turn HTTP/1.1")!)
        _ = router.route(HTTPRequestLine.parse("GET /cmd?arg=stats HTTP/1.1")!)
        Thread.sleep(forTimeInterval: 0.2)
        drainMainQueue()

        XCTAssertTrue(spy.shownChannelIDs.isEmpty, "a settings command's own turn must not open the window")
    }

    /// /status distinguishes a pinned (setup/now) window from a normal one.
    func testStatusShowsPinnedWindow() {
        let (router, _, _) = makeSpyRouter()

        _ = router.route(HTTPRequestLine.parse("GET /cmd?arg=setup HTTP/1.1")!)
        drainMainQueue()

        let status = router.route(HTTPRequestLine.parse("GET /status HTTP/1.1")!)
        XCTAssertTrue(status.contains("window=visible-pinned"), "got: \(status)")
    }

    func testStatsJSONReturnsValidJSON() throws {
        let router = makeRouter()
        let body = router.route(HTTPRequestLine.parse("GET /stats.json HTTP/1.1")!)
        let data = try XCTUnwrap(body.data(using: .utf8))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["waits"] as? Int, 0)
        XCTAssertNotNil(json["wait_seconds"])
        XCTAssertNotNil(json["content_seconds"])
    }
}
