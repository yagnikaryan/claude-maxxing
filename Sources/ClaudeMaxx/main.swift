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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            print("Claude Maxx daemon listening on 127.0.0.1:8765")
        } catch {
            FileHandle.standardError.write("HookServer failed to start: \(error)\n".data(using: .utf8)!)
        }

        menu = Menu(settings: settings, stats: stats, orchestrator: orchestrator)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Graceful listener teardown on quit (Menu's "Quit Claude Maxx" item
        // calls NSApp.terminate(nil), which triggers this).
        server?.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
