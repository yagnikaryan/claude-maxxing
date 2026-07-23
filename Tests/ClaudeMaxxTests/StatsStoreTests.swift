import XCTest
@testable import ClaudeMaxx

final class StatsStoreTests: XCTestCase {
    private var fileURL: URL!
    private var store: StatsStore!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jsonl")
        store = StatsStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        fileURL = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Round-trip

    func testAppendAndReadRoundTripsAllEventTypes() {
        let waitTime = Date(timeIntervalSince1970: 1_000_000)
        let contentTime = Date(timeIntervalSince1970: 1_000_100)
        let offeredTime = Date(timeIntervalSince1970: 1_000_200)
        let watchTime = Date(timeIntervalSince1970: 1_000_300)
        let skipTime = Date(timeIntervalSince1970: 1_000_400)
        let advanceTime = Date(timeIntervalSince1970: 1_000_500)
        let attentionTime = Date(timeIntervalSince1970: 1_000_600)

        store.append(.wait(seconds: 42.5, at: waitTime))
        store.append(.content(
            seconds: 30.0,
            openedBy: .chip,
            closedBy: .stop,
            channel: "shorts",
            at: contentTime
        ))
        store.append(.chip(action: .offered, at: offeredTime))
        store.append(.chip(action: .watch, at: watchTime))
        store.append(.chip(action: .skip, at: skipTime))
        store.append(.advance(at: advanceTime))
        store.append(.attention(at: attentionTime))

        let events = store.allEvents()
        XCTAssertEqual(events.count, 7)

        let wait = events[0]
        XCTAssertEqual(wait.type, .wait)
        XCTAssertEqual(wait.t.timeIntervalSince1970, waitTime.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(wait.seconds, 42.5)
        XCTAssertNil(wait.openedBy)
        XCTAssertNil(wait.closedBy)
        XCTAssertNil(wait.channel)
        XCTAssertNil(wait.action)

        let content = events[1]
        XCTAssertEqual(content.type, .content)
        XCTAssertEqual(content.seconds, 30.0)
        XCTAssertEqual(content.openedBy, .chip)
        XCTAssertEqual(content.closedBy, .stop)
        XCTAssertEqual(content.channel, "shorts")
        XCTAssertNil(content.action)

        let offered = events[2]
        XCTAssertEqual(offered.type, .chip)
        XCTAssertEqual(offered.action, .offered)
        XCTAssertNil(offered.seconds)

        let watch = events[3]
        XCTAssertEqual(watch.type, .chip)
        XCTAssertEqual(watch.action, .watch)

        let skip = events[4]
        XCTAssertEqual(skip.type, .chip)
        XCTAssertEqual(skip.action, .skip)

        let advance = events[5]
        XCTAssertEqual(advance.type, .advance)
        XCTAssertNil(advance.seconds)
        XCTAssertNil(advance.action)

        let attention = events[6]
        XCTAssertEqual(attention.type, .attention)
        XCTAssertNil(attention.seconds)
        XCTAssertNil(attention.action)
    }

    func testCorruptTrailingLineIsSkippedNotFatal() {
        store.append(.wait(seconds: 10, at: Date()))

        // Simulate a crash mid-write: append a partial, undecodable line.
        let handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
        handle?.write("{\"t\":\"garbage\ntype\":\"w".data(using: .utf8)!)
        try? handle?.close()

        let events = store.allEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, .wait)
    }

    // MARK: - Derived metrics

    func testDailyStatsMatchesHandComputedValues() {
        let events: [StatsEvent] = [
            .wait(seconds: 200),
            .wait(seconds: 200),
            .wait(seconds: 200),
            .content(seconds: 60, openedBy: .chip, closedBy: .stop, channel: "shorts"),
            .content(seconds: 60, openedBy: .auto, closedBy: .watchdog, channel: "shorts"),
            .chip(action: .offered),
            .chip(action: .offered),
            .chip(action: .offered),
            .chip(action: .watch),
            .chip(action: .watch),
            .chip(action: .skip),
            .advance(),
            .advance(),
            .advance(),
            .advance(),
            .attention(),
        ]

        let stats = DailyStats(events: events)

        XCTAssertEqual(stats.waits, 3)
        XCTAssertEqual(stats.waitSeconds, 600)
        XCTAssertEqual(stats.contentSeconds, 120)
        XCTAssertEqual(stats.contentToWaitRatio, 0.2, accuracy: 0.0001)
        XCTAssertEqual(stats.videosCompleted, 4)
        XCTAssertEqual(stats.chipOffered, 3)
        XCTAssertEqual(stats.chipWatch, 2)
        XCTAssertEqual(stats.chipSkip, 1)
        XCTAssertEqual(stats.optInRate, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(stats.skipRate, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(stats.interrupts, 1)
    }

    func testDailyStatsGuardsDivisionByZero() {
        let stats = DailyStats(events: [])
        XCTAssertEqual(stats.waitSeconds, 0)
        XCTAssertEqual(stats.contentToWaitRatio, 0)
        XCTAssertEqual(stats.chipOffered, 0)
        XCTAssertEqual(stats.optInRate, 0)
        XCTAssertEqual(stats.skipRate, 0)
    }

    // MARK: - events(on:) filtering + statsJSON shape

    func testEventsOnDateFiltersToCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let day = calendar.date(from: DateComponents(year: 2026, month: 7, day: 22))!
        let inDayMorning = calendar.date(byAdding: .hour, value: 1, to: day)!
        let inDayLate = calendar.date(byAdding: .hour, value: 23, to: day)!
        let previousDay = calendar.date(byAdding: .day, value: -1, to: day)!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!

        store.append(.wait(seconds: 1, at: previousDay))
        store.append(.wait(seconds: 2, at: inDayMorning))
        store.append(.wait(seconds: 3, at: inDayLate))
        store.append(.wait(seconds: 4, at: nextDay))

        let events = store.events(on: day, calendar: calendar)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map { $0.seconds }), Set([2.0, 3.0]))
    }

    func testStatsJSONContainsSnakeCaseKeys() throws {
        store.append(.wait(seconds: 100))
        store.append(.content(seconds: 20, openedBy: .chip, closedBy: .stop, channel: "shorts"))
        store.append(.chip(action: .offered))
        store.append(.chip(action: .watch))
        store.append(.advance())
        store.append(.attention())

        let data = store.statsJSON()
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["waits"] as? Int, 1)
        XCTAssertEqual(json["wait_seconds"] as? Double, 100)
        XCTAssertEqual(json["content_seconds"] as? Double, 20)
        XCTAssertEqual(try XCTUnwrap(json["content_to_wait_ratio"] as? Double), 0.2, accuracy: 0.0001)
        XCTAssertEqual(json["videos_completed"] as? Int, 1)
        XCTAssertEqual(json["chip_offered"] as? Int, 1)
        XCTAssertEqual(json["chip_watch"] as? Int, 1)
        XCTAssertEqual(json["chip_skip"] as? Int, 0)
        XCTAssertNotNil(json["opt_in_rate"])
        XCTAssertNotNil(json["skip_rate"])
        XCTAssertEqual(json["interrupts"] as? Int, 1)
    }
}
