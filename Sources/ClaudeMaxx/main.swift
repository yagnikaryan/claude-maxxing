import AppKit
import Foundation

// One shared Orchestrator instance, constructed explicitly (instead of
// letting Router's default arg build its own) so the menu bar's mode/channel
// actions and HookServer's hook-driven state machine operate on the same
// state — otherwise Menu's `commandOff()` calls would target an Orchestrator
// nothing else ever observes.
let settings = SettingsStore.shared
let stats = StatsStore.shared
let orchestrator = Orchestrator(settings: settings, stats: stats)
let router = Router(settings: settings, stats: stats, orchestrator: orchestrator)
let server = HookServer(router: router)
do {
    try server.start()
    print("Claude Maxx daemon listening on 127.0.0.1:8765")
} catch {
    FileHandle.standardError.write("HookServer failed to start: \(error)\n".data(using: .utf8)!)
}

// Menu bar UI: no Dock icon, no bundle needed for this (App bundle /
// LSUIElement packaging is a separate M1 task, §12 task 7).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menu = Menu(settings: settings, stats: stats, orchestrator: orchestrator)
app.run()
