import AppKit
import Foundation

/// Real `NSApplicationDelegate`-based entry point (final-integration pass —
/// replaces the earlier script-style `main.swift`). Same runtime wiring as
/// before (SettingsStore → StatsStore → panels → Orchestrator → Router →
/// HookServer → Menu), just expressed with explicit lifecycle hooks instead
/// of top-level statements, plus a real termination hook for the listener.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore!
    private var stats: StatsStore!
    private var feedPanel: FeedPanel!
    private var chipPanel: ChipPanel!
    private var orchestrator: Orchestrator!
    private var router: Router!
    private var server: HookServer!
    private var menu: Menu!
    /// Retained for the lifetime of the process — a `DispatchSourceSignal`
    /// stops firing the moment it is deallocated.
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        detachFromSpawningProcessGroup()
        // Deliberately cmLog (stderr, unbuffered) and not print(). The old
        // `print("…listening on 8765")` went to stdout, which is *block
        // buffered* when redirected to a file the way every launcher does it
        // (`nohup … >>"$log" 2>&1`). The line only flushes at a clean exit, so
        // across 20+ process starts it appeared in the log exactly zero
        // times — leaving no way to tell "the daemon restarted" from "the
        // daemon has been up all along".
        cmLog("daemon starting — v\(Version.current) pid=\(getpid()) pgid=\(getpgrp())")
        // No Dock icon / no App Switcher entry. This is the correct,
        // sufficient mechanism for an unbundled SwiftPM executable: there is
        // no `.app`/Info.plist yet for Launch Services to read `LSUIElement`
        // from (that's M3 packaging, §12 task 7/15), and SwiftPM has no
        // supported way to embed one with launch-time effect for an
        // `executableTarget` without a separate bundling step. Must run
        // before any window is created.
        NSApp.setActivationPolicy(.accessory)

        settings = SettingsStore.shared
        stats = StatsStore.shared

        // Built explicitly here (main thread — applicationDidFinishLaunching
        // always runs on main) and injected into Orchestrator's factory
        // closures below, rather than relying on Orchestrator's default
        // lazy `{ ChipPanel() }` / `{ FeedPanel() }` factories.
        feedPanel = FeedPanel(settings: settings)
        // `videos_completed` counts `.advance` events, which only exist if
        // something forwards the channels' `cm` messages into the store.
        feedPanel.onAdvance = { [stats] in stats?.append(.advance()) }
        chipPanel = ChipPanel()

        orchestrator = Orchestrator(
            settings: settings,
            stats: stats,
            chipPresenterFactory: { [chipPanel] in chipPanel! },
            feedPresenterFactory: { [feedPanel] in feedPanel! }
        )

        // Router is the HTTP → Orchestrator translation boundary; HookServer
        // only ever talks to Orchestrator through it (not re-architecting
        // that boundary in this pass).
        router = Router(settings: settings, stats: stats, orchestrator: orchestrator)
        server = HookServer(router: router)
        do {
            try server.start()
            cmLog("listening on 127.0.0.1:8765")
        } catch {
            FileHandle.standardError.write("HookServer failed to start: \(error)\n".data(using: .utf8)!)
        }

        menu = Menu(settings: settings, stats: stats, orchestrator: orchestrator)
        installSignalHandlers()
        cmLog("daemon ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Graceful listener teardown on quit (Menu's "Quit Claude Maxx" item
        // calls NSApp.terminate(nil), which triggers this).
        orchestrator?.shutdown(reason: "applicationWillTerminate")
        server?.stop()
    }

    /// Give the daemon its own session so a signal aimed at the process group
    /// that spawned it cannot take it down with them.
    ///
    /// Every launcher uses `nohup "$bin" &`, which ignores SIGHUP but does
    /// *not* create a new session, so the daemon stayed in the spawning hook's
    /// process group even after reparenting to launchd. A group-wide signal —
    /// how a parent CLI reaps its children, and how a timed-out hook is killed
    /// — reached it there, killing it mid-prompt with no crash report and no
    /// record. Leading suspect for "the window closes by itself".
    ///
    /// EPERM means it is already a group leader (a shell with job control),
    /// which is already isolated — nothing to fix.
    private func detachFromSpawningProcessGroup() {
        if setsid() == -1 {
            cmLog("setsid: already a process-group leader (errno \(errno)) — already isolated")
        }
    }

    /// SIGTERM and friends default to killing the process outright, so AppKit
    /// never runs `applicationWillTerminate` and the daemon vanishes silently.
    /// `DispatchSourceSignal` moves delivery onto a queue where real work is
    /// allowed (a C signal handler could not log or touch the stats store),
    /// but only once the default action is suppressed with SIG_IGN — without
    /// that the process dies before the source ever fires.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                let name = sig == SIGTERM ? "SIGTERM" : (sig == SIGINT ? "SIGINT" : "SIGHUP")
                self?.orchestrator?.shutdown(reason: "received \(name)")
                self?.server?.stop()
                cmLog("daemon exiting on \(name)")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
