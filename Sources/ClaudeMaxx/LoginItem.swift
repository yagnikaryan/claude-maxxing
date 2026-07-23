import Foundation
import ServiceManagement

/// Thin `SMAppService` wrapper for the menu bar's "Launch at Login" toggle
/// (SPEC §12 M1 task 7's login-item half; `LSUIElement`/Dock-hiding is
/// handled separately in `main.swift` via `setActivationPolicy(.accessory)`).
/// Enum namespace, no state of its own — mirrors `ChannelRegistry`'s style.
///
/// Two load-bearing findings from hands-on research (verified with
/// `sfltool dumpbtm` in an isolated scratch binary outside this repo, fully
/// cleaned up afterward):
///
/// 1. `SMAppService.mainApp.register()` creates a **real, visible** macOS
///    Background-Task-Management / "Login Items & Extensions" entry even for
///    a bare, unbundled executable with `Bundle.main.bundleIdentifier == nil`
///    — it keys off the executable's own path, not a bundle identity.
///    `.status` itself reports `.notFound` throughout (there's no bundle
///    identity to resolve), yet the OS-level entry is genuinely `.enabled`.
///    Pre-M3 (no packaged `.app`), toggling this on registers whatever path
///    is currently running — e.g. `.build/arm64-apple-macosx/debug/ClaudeMaxx`
///    under `swift run` — and that entry goes stale across a clean/release
///    rebuild (new path, same intent) until M3 gives the app a stable bundle
///    identity. Document this to the user (README), don't hide it.
/// 2. `unregister()` only succeeds when called by the **same executable**
///    that originally registered — identity is process/path-bound. Calling
///    it from a different compiled binary throws
///    `SMAppServiceErrorDomain Code=1 "Operation not permitted"`.
///
/// Because of finding 1, **this type must never be exercised by an automated
/// test** — doing so would leave a real, possibly-stale login-item entry on
/// the developer's/CI machine. No `LoginItemTests.swift` should be added,
/// and nothing in `Tests/` or in `main.swift`'s startup path may call
/// `LoginItem.setEnabled` automatically. It is reachable only from a manual,
/// user-initiated menu click (`Menu`'s "Launch at Login" item).
enum LoginItem {
    /// Always queries the OS live — never cached — so if the user disables
    /// it from System Settings directly, the menu checkbox reflects reality
    /// the next time the menu opens (mirrors `menuWillOpen`'s refresh-on-open
    /// pattern already used for mode/channel state).
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// `true` when the user must approve the login item in System Settings
    /// before it takes effect — re-registering in this state just comes back
    /// `.requiresApproval` again, so callers should deep-link instead.
    static var requiresApproval: Bool { status == .requiresApproval }

    /// Fail-open, matching the existing StatsStore/HookServer error-
    /// swallowing style — a login-item registration failure must never
    /// crash the daemon.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            FileHandle.standardError.write("LoginItem: failed to set enabled=\(enabled): \(error)\n".data(using: .utf8)!)
            return false
        }
    }

    /// Deep-links to System Settings → General → Login Items & Extensions,
    /// for the `.requiresApproval` case.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
