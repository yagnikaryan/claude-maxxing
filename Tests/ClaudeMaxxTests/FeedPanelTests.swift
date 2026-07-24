import XCTest
import WebKit
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

    /// Regression: without the "Version/x Safari/x" UA suffix, Instagram
    /// classified the webview as an untrusted embedded browser and silently
    /// withheld the `sessionid` cookie after a successful password+captcha
    /// login — so sign-in could never persist. The data store must also
    /// stay persistent (`.default()`, not `.nonPersistent()`), or logins
    /// die on relaunch instead.
    func testWebViewPresentsAsSafariAndPersistsData() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let panel = FeedPanel(settings: settings)

        XCTAssertEqual(panel.webView.configuration.applicationNameForUserAgent, "Version/18.5 Safari/605.1.15")
        XCTAssertTrue(panel.webView.configuration.websiteDataStore.isPersistent)
    }

    /// Regression: `performShow` used to reload whenever `webView.url`
    /// differed from `channel.url`, which is true for every in-site page —
    /// including a login form. `presentWindow` runs on every prompt, so the
    /// user's next message navigated the webview off a half-finished
    /// Instagram login (or TikTok SMS-code screen) back to the feed, and the
    /// sign-in could never complete. Same channel + a page already loaded
    /// must never reload, wherever in the site the user has navigated.
    func testDoesNotReloadWhileUserIsMidLoginOnTheSameChannel() {
        XCTAssertFalse(
            FeedPanel.shouldLoad(loadedIdentity: "reels", newIdentity: "reels", hasLoadedPage: true),
            "re-showing the same channel must leave an in-progress login page alone"
        )
    }

    /// Regression: popups used to be flattened into the main webview, which
    /// severs `window.opener` — and Meta's `auth_platform` login handoff
    /// posts the session back through exactly that, so sign-in could never
    /// complete. A popup must be hosted in its own key-capable window built
    /// from the *configuration WebKit supplies* (a fresh one would put it in
    /// a different content world and lose the opener relationship again).
    ///
    /// `WKWebView` copies the configuration it is handed, so this asserts the
    /// property that survives that copy and actually matters: the popup shares
    /// the opener's data store, which is what lands the session cookie in the
    /// same jar the feed reads from.
    func testPopupSharesOpenerDataStoreAndCanHoldKey() {
        let configuration = WKWebViewConfiguration()
        let popup = PopupPanel(configuration: configuration, windowFeatures: WKWindowFeatures(), relativeTo: nil)

        XCTAssertTrue(
            popup.webView.configuration.websiteDataStore === configuration.websiteDataStore,
            "the popup must write its session cookie into the opener's store"
        )
        XCTAssertTrue(popup.canBecomeKey, "login fields in the popup must be able to take a caret")
        XCTAssertTrue(popup.styleMask.contains(.nonactivatingPanel), "the app itself must never activate")
    }

    /// End-to-end proof of the popup path, driven through a real WKWebView
    /// rather than by calling the delegate by hand: a page that calls
    /// `window.open()` must produce a hosted `PopupPanel` with its own
    /// webview. Covers both halves of the login failure at once — the old
    /// code returned nil here (no popup, opener severed), and a JS-initiated
    /// open is silently discarded unless `javaScriptCanOpenWindowsAutomatically`
    /// is set, since `evaluateJavaScript` carries no user gesture (neither
    /// does an auth callback firing after a captcha verifies).
    func testWindowOpenIsHostedInItsOwnPopupWindow() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let panel = FeedPanel(settings: settings)

        panel.webView.loadHTMLString("<html><body>opener</body></html>", baseURL: URL(string: "https://example.com/")!)
        let loaded = expectation(for: NSPredicate { _, _ in panel.webView.url != nil && !panel.webView.isLoading },
                                 evaluatedWith: panel)
        wait(for: [loaded], timeout: 10)

        panel.webView.evaluateJavaScript("window.open('https://example.com/popup', '_blank');")

        let opened = expectation(for: NSPredicate { _, _ in panel.popupPanels.count == 1 }, evaluatedWith: panel)
        wait(for: [opened], timeout: 10)

        XCTAssertFalse(
            panel.popupPanels[0].webView === panel.webView,
            "the popup must be a second webview, not the feed navigating itself"
        )
    }

    /// The other half of the contract: identity-keyed reloading must still
    /// load on a real channel switch and on the first show of a session.
    func testLoadsOnChannelSwitchAndFirstShow() {
        XCTAssertTrue(
            FeedPanel.shouldLoad(loadedIdentity: "reels", newIdentity: "tiktok", hasLoadedPage: true),
            "switching channels must load the new channel's feed"
        )
        XCTAssertTrue(
            FeedPanel.shouldLoad(loadedIdentity: nil, newIdentity: "reels", hasLoadedPage: false),
            "first show of a session has nothing loaded yet"
        )
    }

    /// The reason `shouldLoad` keys on `contentIdentity` rather than channel
    /// id: picking a different article leaves the channel unchanged, so an
    /// id-keyed comparison saw "reading" == "reading" and silently kept
    /// showing the previous one.
    func testLoadsWhenTheReadingSelectionChangesWithinTheSameChannel() {
        XCTAssertTrue(
            FeedPanel.shouldLoad(
                loadedIdentity: "reading#0#file:///tmp/a.pdf",
                newIdentity: "reading#1#file:///tmp/b.pdf",
                hasLoadedPage: true
            ),
            "choosing another item in the reading list must load it"
        )
    }
}
