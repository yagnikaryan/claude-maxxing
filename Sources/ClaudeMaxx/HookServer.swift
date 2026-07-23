import Foundation
import Network

// MARK: - HTTPRequestLine

/// Parses only the HTTP request line (e.g. `"GET /start?sid=abc HTTP/1.1"`),
/// per SPEC §5 — the daemon never needs headers or a body for any endpoint.
struct HTTPRequestLine {
    let method: String
    let path: String
    let query: [String: String]

    /// Returns `nil` on empty/unparsable input so the caller can fall back to
    /// "unknown endpoint" — this never throws.
    static func parse(_ line: String) -> HTTPRequestLine? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 2 else { return nil }

        let method = String(tokens[0])
        let target = String(tokens[1])

        guard let components = URLComponents(string: target) else { return nil }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }

        return HTTPRequestLine(method: method, path: components.path, query: query)
    }
}

// MARK: - Router

/// Pure request → response text logic, independent of the network layer so
/// it can be exercised without sockets (see HookServerTests).
final class Router {
    private let settings: SettingsStore
    private let stats: StatsStore
    private let stateQueue = DispatchQueue(label: "com.claudemaxx.router.state")

    // TODO(Orchestrator): replace with SessionTracker (sessions dict + anonCount
    // become owned there, plus the watchdog timer per SPEC §5/§6).
    private var sessions: [String: Date] = [:]
    private var anonCount: Int = 0
    // TODO(Orchestrator/PresentationController): replace with real state machine
    // (IDLE/PENDING/OFFERING/SHOWING/ALERTING per SPEC §6).
    private var windowVisible = false

    init(settings: SettingsStore = .shared, stats: StatsStore = .shared) {
        self.settings = settings
        self.stats = stats
    }

    func route(_ request: HTTPRequestLine) -> String {
        switch request.path {
        case "/start":
            return handleStart(request)
        case "/stop":
            return handleStop(request)
        case "/attention":
            return handleAttention()
        case "/cmd":
            return handleCmd(request)
        case "/show":
            return handleShow()
        case "/status":
            return stateQueue.sync { statusLine() }
        case "/stats.json":
            return handleStatsJSON()
        default:
            return "unknown endpoint"
        }
    }

    // MARK: - Session endpoints

    private func handleStart(_ request: HTTPRequestLine) -> String {
        stateQueue.sync {
            // TODO(Orchestrator): count 0→1 should arm the PENDING debounce timer (§6).
            if let sid = request.query["sid"] {
                sessions[sid] = Date()
            } else {
                anonCount += 1
            }
            return "session started (active=\(activeCount))"
        }
    }

    private func handleStop(_ request: HTTPRequestLine) -> String {
        stateQueue.sync {
            // TODO(Orchestrator): count→0 should trigger IDLE transition / snap-back.
            if let sid = request.query["sid"] {
                sessions.removeValue(forKey: sid)
            } else {
                anonCount = max(0, anonCount - 1)
            }
            return "session stopped (active=\(activeCount))"
        }
    }

    private func handleAttention() -> String {
        // TODO(Orchestrator): channel-aware pause/banner + NSApp.requestUserAttention (§8.4).
        "attention received"
    }

    // MARK: - /cmd grammar (§4.2)

    private func handleCmd(_ request: HTTPRequestLine) -> String {
        let arg = (request.query["arg"] ?? "").trimmingCharacters(in: .whitespaces)
        switch arg {
        case "auto":
            settings.mode = .auto
            return "claude-maxx mode set to auto"
        case "ask":
            settings.mode = .ask
            return "claude-maxx mode set to ask"
        case "off":
            settings.mode = .off
            // TODO(Orchestrator): hide chip + window.
            return "claude-maxx mode set to off"
        case "now":
            // TODO(Orchestrator/Panels): actually show window.
            stateQueue.sync { windowVisible = true }
            return "opening window"
        case "scroll on":
            settings.autoAdvance = true
            return "auto-advance on"
        case "scroll off":
            settings.autoAdvance = false
            return "auto-advance off"
        case "stats":
            return statsLine()
        case "status", "":
            return stateQueue.sync { statusLine() }
        default:
            return "unknown claude-maxx command: \(arg)"
        }
    }

    // MARK: - /show, /status, /stats.json

    private func handleShow() -> String {
        // TODO(Orchestrator/Panels): real window presentation.
        stateQueue.sync { windowVisible = true }
        return "showing window"
    }

    private func handleStatsJSON() -> String {
        String(data: stats.statsJSON(for: Date()), encoding: .utf8) ?? "{}"
    }

    // MARK: - Shared body builders

    /// Must be called on `stateQueue`.
    private func statusLine() -> String {
        "mode=\(settings.mode.rawValue) active_sessions=\(activeCount) window=\(windowVisible ? "visible" : "hidden") auto_advance=\(settings.autoAdvance)"
    }

    private func statsLine() -> String {
        let daily = stats.dailyStats(for: Date())
        let contentMinutes = Int(daily.contentSeconds / 60)
        let waitMinutes = Int(daily.waitSeconds / 60)
        return "today: \(daily.waits) waits, \(contentMinutes)m content / \(waitMinutes)m waiting, \(daily.chipWatch)/\(daily.chipOffered) watched"
    }

    /// Must be called on `stateQueue`.
    private var activeCount: Int {
        sessions.count + anonCount
    }
}

// MARK: - HookServer

/// Raw-TCP HTTP accept loop (SPEC §5). Binds 127.0.0.1 exclusively, parses
/// only the request line, and always responds 200 text/plain — fail-open
/// end to end, never 500.
final class HookServer {
    private let port: NWEndpoint.Port
    private let router: Router
    private let queue = DispatchQueue(label: "com.claudemaxx.hookserver")
    private var listener: NWListener?
    private static let maxRequestLineBytes = 8192

    init(port: UInt16 = 8765, router: Router = Router()) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            fatalError("HookServer: invalid port \(port)")
        }
        self.port = nwPort
        self.router = router
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Critical invariant (SPEC §5): bind 127.0.0.1 exclusively, never
        // 0.0.0.0. NWListener has no direct "host" argument on its
        // initializer — requiredLocalEndpoint is what constrains the bind
        // to loopback only.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        let newListener = try NWListener(using: parameters)
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                // Non-fatal — the daemon must not crash the process on
                // listener errors.
                FileHandle.standardError.write(
                    "HookServer: listener failed: \(error)\n".data(using: .utf8)!
                )
            }
        }
        newListener.start(queue: queue)
        listener = newListener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequestLine(on: connection, accumulated: Data())
    }

    private func receiveRequestLine(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                let line = String(data: lineData, encoding: .utf8) ?? ""
                self.respond(to: line.trimmingCharacters(in: .whitespacesAndNewlines), on: connection)
                return
            }

            // Fail-open: no newline yet. If the connection is done or we've
            // exceeded the bound, respond with whatever bytes we have rather
            // than hanging forever.
            if error != nil || isComplete || buffer.count >= Self.maxRequestLineBytes {
                let line = String(data: buffer, encoding: .utf8) ?? ""
                self.respond(to: line.trimmingCharacters(in: .whitespacesAndNewlines), on: connection)
                return
            }

            self.receiveRequestLine(on: connection, accumulated: buffer)
        }
    }

    private func respond(to requestLine: String, on connection: NWConnection) {
        let body: String
        if let request = HTTPRequestLine.parse(requestLine) {
            body = router.route(request)
        } else {
            body = "unknown endpoint"
        }

        let response = Self.httpResponse(body: body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func httpResponse(body: String) -> Data {
        let bodyData = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var data = header.data(using: .utf8) ?? Data()
        data.append(bodyData)
        return data
    }
}
