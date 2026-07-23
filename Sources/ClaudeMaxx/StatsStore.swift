import Foundation

// MARK: - Event vocabulary (SPEC §9.2)

/// `type` discriminator for a StatsEvent row.
enum StatsEventType: String, Codable {
    case wait
    case content
    case chip
    case advance
    case attention
}

/// `chip.action` values (§9.2).
enum ChipAction: String, Codable {
    case offered
    case watch
    case skip
}

/// `content.openedBy` values (§9.2).
enum ContentOpenedBy: String, Codable {
    case auto
    case chip
    case cmd
    case menu
    case http
}

/// `content.closedBy` values (§9.2).
enum ContentClosedBy: String, Codable {
    case stop
    case cmd
    case watchdog
    case cap
    case quit
}

/// One row of the append-only StatsStore event log (§9.2). Stored properties
/// are Optional so Swift's synthesized Codable conformance only emits the keys
/// relevant to a given `type` (via encodeIfPresent/decodeIfPresent) — a `wait`
/// row carries `seconds` and nothing else, a `chip` row carries `action`, etc.
struct StatsEvent: Codable {
    let t: Date
    let type: StatsEventType

    /// wait, content
    let seconds: Double?
    /// content
    let openedBy: ContentOpenedBy?
    /// content
    let closedBy: ContentClosedBy?
    /// content
    let channel: String?
    /// chip
    let action: ChipAction?

    init(
        t: Date,
        type: StatsEventType,
        seconds: Double? = nil,
        openedBy: ContentOpenedBy? = nil,
        closedBy: ContentClosedBy? = nil,
        channel: String? = nil,
        action: ChipAction? = nil
    ) {
        self.t = t
        self.type = type
        self.seconds = seconds
        self.openedBy = openedBy
        self.closedBy = closedBy
        self.channel = channel
        self.action = action
    }
}

// MARK: - Ergonomic factory statics (future SessionTracker/PresentationController call sites)

extension StatsEvent {
    /// IDLE entry — one per wait episode, spanning first `/start` to last `/stop`.
    static func wait(seconds: Double, at t: Date = Date()) -> StatsEvent {
        StatsEvent(t: t, type: .wait, seconds: seconds)
    }

    /// Window hide — one per SHOWING episode.
    static func content(
        seconds: Double,
        openedBy: ContentOpenedBy,
        closedBy: ContentClosedBy,
        channel: String,
        at t: Date = Date()
    ) -> StatsEvent {
        StatsEvent(
            t: t,
            type: .content,
            seconds: seconds,
            openedBy: openedBy,
            closedBy: closedBy,
            channel: channel
        )
    }

    /// Chip presented / button tapped.
    static func chip(action: ChipAction, at t: Date = Date()) -> StatsEvent {
        StatsEvent(t: t, type: .chip, action: action)
    }

    /// Injected JS detects watch-complete.
    static func advance(at t: Date = Date()) -> StatsEvent {
        StatsEvent(t: t, type: .advance)
    }

    /// `/attention` received.
    static func attention(at t: Date = Date()) -> StatsEvent {
        StatsEvent(t: t, type: .attention)
    }
}

// MARK: - Derived metrics (§9.3) / `/stats.json` shape

/// One day's derived metrics, computed by scanning that day's events (§9.3).
/// `CodingKeys` map to the snake_case `/stats.json` shape shown in §9.3.
struct DailyStats: Encodable {
    let waits: Int
    let waitSeconds: Double
    let contentSeconds: Double
    /// Σ content.seconds / Σ wait.seconds; 0 when waitSeconds == 0 (guards div-by-zero).
    let contentToWaitRatio: Double
    let videosCompleted: Int
    let chipOffered: Int
    let chipWatch: Int
    let chipSkip: Int
    /// chip.watch / chip.offered; 0 when chipOffered == 0.
    let optInRate: Double
    /// chip.skip / chip.offered; 0 when chipOffered == 0.
    let skipRate: Double
    let interrupts: Int

    enum CodingKeys: String, CodingKey {
        case waits
        case waitSeconds = "wait_seconds"
        case contentSeconds = "content_seconds"
        case contentToWaitRatio = "content_to_wait_ratio"
        case videosCompleted = "videos_completed"
        case chipOffered = "chip_offered"
        case chipWatch = "chip_watch"
        case chipSkip = "chip_skip"
        case optInRate = "opt_in_rate"
        case skipRate = "skip_rate"
        case interrupts = "interrupts"
    }

    init(events: [StatsEvent]) {
        let waitEvents = events.filter { $0.type == .wait }
        let contentEvents = events.filter { $0.type == .content }
        let chipEvents = events.filter { $0.type == .chip }

        waits = waitEvents.count
        waitSeconds = waitEvents.reduce(0) { $0 + ($1.seconds ?? 0) }
        contentSeconds = contentEvents.reduce(0) { $0 + ($1.seconds ?? 0) }
        contentToWaitRatio = waitSeconds == 0 ? 0 : contentSeconds / waitSeconds

        videosCompleted = events.filter { $0.type == .advance }.count

        chipOffered = chipEvents.filter { $0.action == .offered }.count
        chipWatch = chipEvents.filter { $0.action == .watch }.count
        chipSkip = chipEvents.filter { $0.action == .skip }.count
        optInRate = chipOffered == 0 ? 0 : Double(chipWatch) / Double(chipOffered)
        skipRate = chipOffered == 0 ? 0 : Double(chipSkip) / Double(chipOffered)

        interrupts = events.filter { $0.type == .attention }.count
    }
}

// MARK: - StatsStore

/// Append-only JSONL event log at
/// `~/Library/Application Support/ClaudeMaxx/stats.jsonl` (§9.2).
///
/// Event sourcing, not pre-aggregated counters: raw events are appended at
/// each state-machine transition and every metric is derived at read time.
/// Local only; never transmitted.
///
/// Stats logging must never crash or block the daemon — all failures are
/// caught, logged to stderr, and swallowed (fail-open, per SPEC's overall
/// philosophy).
final class StatsStore {
    static let shared = StatsStore()

    private let fileURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.claudemaxx.statsstore")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Injectable file URL + FileManager for isolated testing; production
    /// code uses the default-backed `shared`.
    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("ClaudeMaxx", isDirectory: true)
            .appendingPathComponent("stats.jsonl")
    }

    /// Appends one JSONL line for `event`. Never throws; failures are logged
    /// to stderr and swallowed so stats logging can never crash or block the
    /// daemon.
    func append(_ event: StatsEvent) {
        queue.sync {
            do {
                try ensureFileExists()
                let data = try encoder.encode(event)
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
                handle.write("\n".data(using: .utf8)!)
            } catch {
                FileHandle.standardError.write(
                    "StatsStore: failed to append event: \(error)\n".data(using: .utf8)!
                )
            }
        }
    }

    /// Reads and decodes every event in the log. Lines that fail to decode
    /// (e.g. a partial trailing line from a crash mid-write) are skipped
    /// rather than failing the whole read.
    func allEvents() -> [StatsEvent] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8)
            else { return [] }

            return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
                guard let lineData = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(StatsEvent.self, from: lineData)
            }
        }
    }

    /// Events whose `t` falls within `[startOfDay, startOfDay + 1 day)` for
    /// `date` in `calendar`.
    func events(on date: Date, calendar: Calendar = .current) -> [StatsEvent] {
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return []
        }
        return allEvents().filter { $0.t >= startOfDay && $0.t < endOfDay }
    }

    /// Derived metrics for `date` (§9.3).
    func dailyStats(for date: Date = Date(), calendar: Calendar = .current) -> DailyStats {
        DailyStats(events: events(on: date, calendar: calendar))
    }

    /// Serialized `DailyStats` for `date`, sorted-keys for determinism. This
    /// is what `GET /stats.json` hands back verbatim.
    func statsJSON(for date: Date = Date(), calendar: Calendar = .current) -> Data {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.sortedKeys]
        return (try? jsonEncoder.encode(dailyStats(for: date, calendar: calendar))) ?? Data()
    }

    private func ensureFileExists() throws {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
    }
}
