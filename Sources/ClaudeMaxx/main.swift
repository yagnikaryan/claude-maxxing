import AppKit
import Foundation

/// Entry point. Wiring order: SettingsStore → StatsStore → panels →
/// Orchestrator → Router → HookServer → Menu.
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
        cmLog("daemon starting — v\(Version.current) pid=\(getpid()) pgid=\(getpgrp())")
        // No Dock icon / App Switcher entry. An unbundled SwiftPM executable has
        // no Info.plist for Launch Services to read `LSUIElement` from, so this
        // is the only mechanism; must run before any window is created.
        NSApp.setActivationPolicy(.accessory)

        settings = SettingsStore.shared
        stats = StatsStore.shared

        // Injected into Orchestrator's factories below rather than left to its
        // lazy defaults, so both panels are built here on main.
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
        // only ever talks to Orchestrator through it. The injected `terminate`
        // differs from Router's default only in recording an open episode when
        // the watchdog bypasses AppKit — same sequence as the signal handlers.
        router = Router(
            settings: settings,
            stats: stats,
            orchestrator: orchestrator,
            terminate: { [weak self] in
                QuitTerminator.daemon(beforeExit: {
                    self?.orchestrator?.shutdown(reason: "quit watchdog")
                    self?.server?.stop()
                }).schedule()
            }
        )
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

    /// Own session, so a signal aimed at the spawning hook's process group can't
    /// take the daemon with it (see CLAUDE.md). EPERM means it is already a group
    /// leader, which is already isolated.
    private func detachFromSpawningProcessGroup() {
        if setsid() == -1 {
            cmLog("setsid: already a process-group leader (errno \(errno)) — already isolated")
        }
    }

    /// `SIG_IGN` first is load-bearing: without it the default action kills the
    /// process before the source fires (see CLAUDE.md).
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
