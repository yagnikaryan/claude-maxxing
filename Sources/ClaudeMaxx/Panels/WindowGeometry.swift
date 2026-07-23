import AppKit

/// Pure window-geometry math for ChipPanel/FeedPanel, per SPEC §7.1.
///
/// This enum is deliberately AppKit-math-only: it uses `NSRect`/`NSSize`/
/// `NSPoint` as value types but never reaches for `NSScreen` or `NSEvent`
/// global lookups itself. Callers (ChipPanel now, FeedPanel later) read
/// those globals once at the AppKit boundary and pass the results in as
/// plain data (`ScreenInfo`, a mouse location), which is what makes this
/// type testable without a live display.
enum WindowGeometry {
    static let margin: CGFloat = 16
    static let minWidth: CGFloat = 240        // §7.1 rule 6 floor
    static let restoreValidationInset: CGFloat = 40   // §7.1 rule 4

    /// Decouples the math from real NSScreen (which has no public initializer,
    /// so it can't be constructed in tests) — any NSScreen or a test fixture
    /// can produce one.
    struct ScreenInfo: Equatable {
        let frame: NSRect
        let visibleFrame: NSRect
    }

    /// FeedPanel anchors bottom-right; ChipPanel anchors top-right (§7.1 rule 5
    /// "mirrored to visible.maxY").
    enum Corner {
        case bottomRight
        case topRight
    }

    // MARK: Rule 1+2 — clamp height first, derive width, re-clamp height if width bit.

    static func clampedSize(desired: NSSize, aspectRatio: NSSize, visibleFrame: NSRect, margin: CGFloat = margin) -> NSSize {
        let availH = visibleFrame.height - 2 * margin
        var height = min(desired.height, availH)
        var width = (height * aspectRatio.width / aspectRatio.height).rounded()

        let availW = visibleFrame.width - 2 * margin
        if width > availW {
            width = availW
            height = (width * aspectRatio.height / aspectRatio.width).rounded()
        }

        return NSSize(width: width, height: height)
    }

    // MARK: Rule 3 (position half) — place an already-clamped size at a screen corner.

    static func anchoredOrigin(size: NSSize, visibleFrame: NSRect, corner: Corner, margin: CGFloat = margin) -> NSPoint {
        let x = visibleFrame.maxX - size.width - margin
        let y: CGFloat
        switch corner {
        case .bottomRight:
            y = visibleFrame.minY + margin
        case .topRight:
            y = visibleFrame.maxY - size.height - margin
        }
        return NSPoint(x: x, y: y)
    }

    // MARK: Rule 3 (screen-selection half) — screen under NSEvent.mouseLocation, else fallback.

    static func targetScreen(mouseLocation: NSPoint, screens: [ScreenInfo], fallback: ScreenInfo) -> ScreenInfo {
        // NSScreen.frame and NSEvent.mouseLocation share the same
        // bottom-left-origin global coordinate space, so no conversion is
        // needed here — matches spec wording exactly.
        screens.first(where: { $0.frame.contains(mouseLocation) }) ?? fallback
    }

    // MARK: Rules 1-3 composed — the "fresh show" frame used when there's no valid restored frame.

    static func freshFrame(desiredSize: NSSize, aspectRatio: NSSize, screen: ScreenInfo, corner: Corner, margin: CGFloat = margin) -> NSRect {
        let size = clampedSize(desired: desiredSize, aspectRatio: aspectRatio, visibleFrame: screen.visibleFrame, margin: margin)
        let origin = anchoredOrigin(size: size, visibleFrame: screen.visibleFrame, corner: corner, margin: margin)
        return NSRect(origin: origin, size: size)
    }

    // MARK: Rule 4 — is a restored (or currently-live, for rule 5) frame still on-screen?

    static func isRestorable(_ frame: NSRect, screens: [ScreenInfo], inset: CGFloat = restoreValidationInset) -> Bool {
        let insetFrame = frame.insetBy(dx: inset, dy: inset)
        return screens.contains { $0.visibleFrame.intersects(insetFrame) }
    }

    // MARK: Which current screen a (valid) frame sits on — helper for reclamped().

    static func containingScreen(for frame: NSRect, screens: [ScreenInfo], fallback: ScreenInfo) -> ScreenInfo {
        screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? fallback
    }

    // MARK: Rule 4 composed — apply restored frame verbatim if valid, else fall back to rule 3.

    static func resolvedFrame(
        restored: NSRect?,
        desiredSize: NSSize,
        aspectRatio: NSSize,
        screens: [ScreenInfo],
        mouseLocation: NSPoint,
        fallbackScreen: ScreenInfo,
        corner: Corner
    ) -> NSRect {
        if let restored, isRestorable(restored, screens: screens) {
            return restored
        }
        let target = targetScreen(mouseLocation: mouseLocation, screens: screens, fallback: fallbackScreen)
        return freshFrame(desiredSize: desiredSize, aspectRatio: aspectRatio, screen: target, corner: corner)
    }

    // MARK: Rule 5 — on didChangeScreenParameters, re-validate + re-clamp + re-anchor a currently-visible frame.

    static func reclamped(
        currentFrame: NSRect,
        aspectRatio: NSSize,
        screens: [ScreenInfo],
        mouseLocation: NSPoint,
        fallbackScreen: ScreenInfo,
        corner: Corner
    ) -> NSRect {
        guard isRestorable(currentFrame, screens: screens) else {
            // Screen unplugged mid-session — same fallback as resolvedFrame.
            // The old screen (and whatever shape the user resized to on it)
            // is gone, so falling back to the channel's default aspectRatio
            // for a fresh placement is reasonable here.
            let target = targetScreen(mouseLocation: mouseLocation, screens: screens, fallback: fallbackScreen)
            return freshFrame(desiredSize: currentFrame.size, aspectRatio: aspectRatio, screen: target, corner: corner)
        }
        let screen = containingScreen(for: currentFrame, screens: screens, fallback: fallbackScreen)
        // Preserve currentFrame's OWN proportions, not the channel's fixed
        // aspectRatio. Reclamping (rule 5) is a "keep it on-screen" safety
        // net for display changes, not a live aspect-ratio enforcer — that
        // AppKit-level lock (contentAspectRatio) was deliberately removed
        // from FeedPanel so users can freely resize to fit sites like
        // Instagram/TikTok. Passing the fixed channel aspect here would
        // silently snap a freely-resized window back to 9:16 on the very
        // next monitor plug/unplug or resolution change — undoing that fix.
        // clampedSize still shrinks an oversized frame to fit a smaller
        // screen; it just does so proportionally to the user's own shape.
        let liveAspect = currentFrame.width > 0 && currentFrame.height > 0 ? currentFrame.size : aspectRatio
        let size = clampedSize(desired: currentFrame.size, aspectRatio: liveAspect, visibleFrame: screen.visibleFrame)
        let origin = anchoredOrigin(size: size, visibleFrame: screen.visibleFrame, corner: corner)
        return NSRect(origin: origin, size: size)
    }

    // MARK: Rule 6 — resize floor for panel.minSize, aspect-locked.

    static func minSize(aspectRatio: NSSize) -> NSSize {
        NSSize(width: minWidth, height: (minWidth * aspectRatio.height / aspectRatio.width).rounded())
    }
}
