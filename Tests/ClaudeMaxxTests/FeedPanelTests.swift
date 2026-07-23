import XCTest
@testable import ClaudeMaxx

/// The one place a real `FeedPanel` (and its WKWebView) is constructed in
/// tests — key-window policy can't be asserted through the `FeedPresenting`
/// spies, and it's exactly the property that silently broke login typing.
final class FeedPanelTests: XCTestCase {

    /// Regression: a borderless panel defaults to `canBecomeKey == false`,
    /// which left the webview permanently blurred — no caret in any login
    /// form, typing impossible. The fix is the pair asserted here: the
    /// panel may hold key (`canBecomeKey`), but only takes it when a click
    /// lands on a view that requests it (`becomesKeyOnlyIfNeeded`), never
    /// merely by being shown.
    func testPanelCanBecomeKeyOnClickButNeverGrabsIt() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let panel = FeedPanel(settings: settings)

        XCTAssertTrue(panel.canBecomeKey, "webview focus (login typing) requires key eligibility")
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded, "key must arrive via user click, not via show")
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "the app itself must never activate")
        XCTAssertFalse(panel.styleMask.contains(.closable), "no close button by design (SPEC §7)")
    }
}
