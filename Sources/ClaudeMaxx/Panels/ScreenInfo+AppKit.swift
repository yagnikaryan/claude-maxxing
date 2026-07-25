import AppKit

/// The AppKit boundary `WindowGeometry` deliberately refuses to cross. That enum
/// works in plain `ScreenInfo` values so its math stays testable without a display,
/// which leaves someone to read the real globals once — and both panels were doing
/// it inline, five times between them. That is the shape where a fix to the
/// no-displays fallback lands on one call site and quietly misses the rest.
///
/// Kept in its own file so `WindowGeometry.swift` remains literally NSScreen-free.
extension WindowGeometry.ScreenInfo {
    init(_ screen: NSScreen) {
        self.init(frame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    static var all: [WindowGeometry.ScreenInfo] {
        NSScreen.screens.map(WindowGeometry.ScreenInfo.init)
    }

    /// `nil` means no displays at all; callers skip placing the window rather than
    /// crash.
    static var main: WindowGeometry.ScreenInfo? {
        (NSScreen.main ?? NSScreen.screens.first).map(WindowGeometry.ScreenInfo.init)
    }
}
