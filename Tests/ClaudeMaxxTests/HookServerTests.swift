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
        return Router(settings: settings, stats: stats)
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
        XCTAssertEqual(status, "mode=ask active_sessions=1 window=hidden auto_advance=true")
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
