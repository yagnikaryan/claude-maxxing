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
            FeedPanel.shouldLoad(previousChannelID: "reels", newChannelID: "reels", hasLoadedPage: true),
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

    /// The other half of the contract: identity-keyed reloading must still
    /// load on a real channel switch and on the first show of a session.
    func testLoadsOnChannelSwitchAndFirstShow() {
        XCTAssertTrue(
            FeedPanel.shouldLoad(previousChannelID: "reels", newChannelID: "tiktok", hasLoadedPage: true),
            "switching channels must load the new channel's feed"
        )
        XCTAssertTrue(
            FeedPanel.shouldLoad(previousChannelID: nil, newChannelID: "reels", hasLoadedPage: false),
            "first show of a session has nothing loaded yet"
        )
    }
}
