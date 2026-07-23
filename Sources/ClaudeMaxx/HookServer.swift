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
    private let orchestrator: Orchestrator

    init(settings: SettingsStore = .shared, stats: StatsStore = .shared, orchestrator: Orchestrator? = nil) {
        self.settings = settings
        self.stats = stats
        self.orchestrator = orchestrator ?? Orchestrator(settings: settings, stats: stats)
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
            return statusLine()
        case "/stats.json":
            return handleStatsJSON()
        default:
            return "unknown endpoint"
        }
    }

    // MARK: - Session endpoints

    private func handleStart(_ request: HTTPRequestLine) -> String {
        orchestrator.start(sid: request.query["sid"])
    }

    private func handleStop(_ request: HTTPRequestLine) -> String {
        orchestrator.stop(sid: request.query["sid"])
    }

    private func handleAttention() -> String {
        orchestrator.attention()
    }

    // MARK: - /cmd grammar (§4.2)

    private func handleCmd(_ request: HTTPRequestLine) -> String {
        // "+" → " ": form-style encoding of a space, which URLComponents
        // deliberately does not decode in query items — accepted here so a
        // hand-typed `curl "?arg=scroll+on"` behaves like the command file's
        // properly percent-encoded `scroll%20on`.
        let arg = (request.query["arg"] ?? "")
            .replacingOccurrences(of: "+", with: " ")
            .trimmingCharacters(in: .whitespaces)

        // Every arg except `now`/`setup` (which *want* the window) first
        // suppresses the current wait's presentation: this /cmd request is
        // almost always the embedded curl of the `/claude-maxx` turn itself,
        // whose own UserPromptSubmit already armed the debounce — and a
        // model turn routinely outlives showDelay, so without this a plain
        // settings command flashes the window/chip for its own turn.
        // (`off` gets the stronger commandOff below, which also closes an
        // open window.)
        switch arg {
        case "now", "setup", "off":
            break
        default:
            orchestrator.suppressCurrentWait()
        }

        switch arg {
        case "auto":
            settings.mode = .auto
            return "claude-maxx mode set to auto"
        case "ask":
            settings.mode = .ask
            return "claude-maxx mode set to ask"
        case "off":
            settings.mode = .off
            orchestrator.commandOff()
            return "claude-maxx mode set to off"
        case "now":
            orchestrator.showNow(openedBy: .cmd)
            return "opening window"
        case "setup":
            orchestrator.showNow(openedBy: .cmd)
            return """
                opening window — Claude Maxx setup:
                1. The window that just opened stays pinned open (it ignores prompt endings) so you can take your time.
                2. Pick a channel from the CM menu bar icon (Shorts / X / Reading / Reels / TikTok) — the open window switches live.
                3. Log into each platform you want directly in the window. One-time: logins persist across relaunches.
                4. Test autoscroll with /claude-maxx scroll on|off — it applies to the open window immediately.
                5. Done? /claude-maxx hide closes the window (it has no close button by design). Then pick a mode: /claude-maxx ask (a chip offers the feed each prompt) or auto (opens by itself while prompts run).
                """
        case "scroll on":
            settings.autoAdvance = true
            orchestrator.refreshIfShowing()   // apply to an already-open window, not just the next show
            return "auto-advance on"
        case "scroll off":
            settings.autoAdvance = false
            orchestrator.refreshIfShowing()
            return "auto-advance off"
        case "hide", "done":
            let mode = settings.mode.rawValue
            orchestrator.commandOff()
            return "window hidden — mode stays \(mode)"
        case "stats":
            return statsLine()
        case "status", "":
            return statusLine()
        default:
            return "unknown claude-maxx command: \(arg)"
        }
    }

    // MARK: - /show, /status, /stats.json

    private func handleShow() -> String {
        orchestrator.showNow(openedBy: .http)
        return "showing window"
    }

    private func handleStatsJSON() -> String {
        String(data: stats.statsJSON(for: Date()), encoding: .utf8) ?? "{}"
    }

    // MARK: - Shared body builders

    private func statusLine() -> String {
        // "visible-pinned" = a Show Window Now / now/setup window that
        // ignores prompt endings — the answer to "why isn't it closing?".
        let window = orchestrator.isWindowPinned
            ? "visible-pinned"
            : (orchestrator.isWindowVisible ? "visible" : "hidden")
        return "mode=\(settings.mode.rawValue) active_sessions=\(orchestrator.activeSessionCount) window=\(window) auto_advance=\(settings.autoAdvance)"
    }

    private func statsLine() -> String {
        let daily = stats.dailyStats(for: Date())
        let contentMinutes = Int(daily.contentSeconds / 60)
        let waitMinutes = Int(daily.waitSeconds / 60)
        return "today: \(daily.waits) waits, \(contentMinutes)m content / \(waitMinutes)m waiting, \(daily.chipWatch)/\(daily.chipOffered) watched"
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
