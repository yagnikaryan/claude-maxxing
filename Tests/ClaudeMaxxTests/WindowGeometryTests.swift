import XCTest
@testable import ClaudeMaxx

final class WindowGeometryTests: XCTestCase {

    // MARK: - 1. 13" laptop, default chip show

    func testFreshFrameOnLaptopFitsFullyInsideVisibleArea() {
        let laptop = WindowGeometry.ScreenInfo(
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875)
        )

        let chipSize = NSSize(width: 260, height: 76)
        let frame = WindowGeometry.freshFrame(
            desiredSize: chipSize,
            aspectRatio: chipSize,
            screen: laptop,
            corner: .topRight
        )

        // Comfortably under the 1408×843 available box, so unclamped.
        XCTAssertEqual(frame, NSRect(x: 1164, y: 783, width: 260, height: 76))

        XCTAssertLessThanOrEqual(frame.maxX, laptop.visibleFrame.maxX)
        XCTAssertLessThanOrEqual(frame.maxY, laptop.visibleFrame.maxY)
        XCTAssertGreaterThanOrEqual(frame.minX, laptop.visibleFrame.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, laptop.visibleFrame.minY)
    }

    // MARK: - 2. Restored frame on a now-missing external monitor

    func testResolvedFrameFallsBackWhenRestoredFrameIsOffScreen() {
        let laptop = WindowGeometry.ScreenInfo(
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875)
        )
        let screens = [laptop]

        // Previously on an external monitor to the right, now unplugged.
        let restored = NSRect(x: 1500, y: 100, width: 400, height: 711)

        XCTAssertFalse(WindowGeometry.isRestorable(restored, screens: screens))

        let resolved = WindowGeometry.resolvedFrame(
            restored: restored,
            desiredSize: NSSize(width: 400, height: 711),
            aspectRatio: NSSize(width: 9, height: 16),
            screens: screens,
            mouseLocation: NSPoint(x: 700, y: 400),
            fallbackScreen: laptop,
            corner: .bottomRight
        )

        // height = min(711, 843) = 711; width = round(711*9/16) = 400
        // origin x = 1440 - 400 - 16 = 1024; y = 0 + 16 = 16
        XCTAssertEqual(resolved, NSRect(x: 1024, y: 16, width: 400, height: 711))
    }

    // MARK: - 3. Width-then-height reclamping

    func testClampedSizeReclampsHeightAfterWidthClampTrips() {
        let narrowPortrait = NSRect(x: 0, y: 0, width: 340, height: 1000)

        let size = WindowGeometry.clampedSize(
            desired: NSSize(width: 400, height: 711),
            aspectRatio: NSSize(width: 9, height: 16),
            visibleFrame: narrowPortrait
        )

        // height-first pass: height=711, width=round(711*9/16)=400
        // 400 > availW(308) trips the width-clamp branch:
        // width=308, height=round(308*16/9)=548
        XCTAssertEqual(size, NSSize(width: 308, height: 548))

        let screen = WindowGeometry.ScreenInfo(frame: narrowPortrait, visibleFrame: narrowPortrait)
        let frame = WindowGeometry.freshFrame(
            desiredSize: NSSize(width: 400, height: 711),
            aspectRatio: NSSize(width: 9, height: 16),
            screen: screen,
            corner: .bottomRight
        )

        XCTAssertLessThanOrEqual(frame.maxX, narrowPortrait.maxX)
        XCTAssertLessThanOrEqual(frame.maxY, narrowPortrait.maxY)
        XCTAssertGreaterThanOrEqual(frame.minX, narrowPortrait.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, narrowPortrait.minY)
    }

    // MARK: - Direct primitive checks

    func testTargetScreenPicksScreenContainingMousePoint() {
        let left = WindowGeometry.ScreenInfo(
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875)
        )
        let right = WindowGeometry.ScreenInfo(
            frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 1440, y: 0, width: 1920, height: 1055)
        )

        let picked = WindowGeometry.targetScreen(
            mouseLocation: NSPoint(x: 2000, y: 500),
            screens: [left, right],
            fallback: left
        )

        XCTAssertEqual(picked, right)
    }

    func testIsRestorableTrueWhenFrameSafelyInsideOneScreen() {
        let laptop = WindowGeometry.ScreenInfo(
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875)
        )
        let frame = NSRect(x: 100, y: 100, width: 400, height: 300)

        XCTAssertTrue(WindowGeometry.isRestorable(frame, screens: [laptop]))
    }

    func testMinSizeIsAspectLockedAtWidthFloor() {
        let size = WindowGeometry.minSize(aspectRatio: NSSize(width: 9, height: 16))
        XCTAssertEqual(size, NSSize(width: 240, height: 427))
    }

    // MARK: - Regression: reclamped must not snap a freely-resized window
    // back to the channel's fixed aspect ratio on a display-change event.

    func testReclampedPreservesUserResizedAspectRatioNotChannelDefault() {
        let laptop = WindowGeometry.ScreenInfo(
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875)
        )
        // The user freely resized the window much wider than tall — exactly
        // what FeedPanel's removed contentAspectRatio lock now allows, e.g.
        // to fit Instagram/TikTok's desktop layout without clipping.
        let userResizedFrame = NSRect(x: 100, y: 100, width: 900, height: 400)

        let reclamped = WindowGeometry.reclamped(
            currentFrame: userResizedFrame,
            aspectRatio: NSSize(width: 9, height: 16),   // channel's fixed default — must NOT win
            screens: [laptop],
            mouseLocation: NSPoint(x: 700, y: 400),
            fallbackScreen: laptop,
            corner: .bottomRight
        )

        // Comfortably fits the screen, so the size must be preserved
        // verbatim — not reshaped toward 9:16 (which would force width down
        // to roughly 400*9/16 ≈ 225).
        XCTAssertEqual(reclamped.size, userResizedFrame.size)
    }
}
