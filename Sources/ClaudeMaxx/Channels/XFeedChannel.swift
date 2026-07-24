import AppKit
import WebKit

/// The X (Twitter) home feed (SPEC §8.3).
///
/// Ambient, with **no auto-scroll at all**. An earlier build drove §8.3's
/// literal 2px/30ms creep, paused on hover; a timeline you read at your own
/// pace gains nothing from the page moving under the pointer, so it was
/// removed. The user scrolls; the channel just hosts the page — which is why
/// there is no user script and nothing to pause.
struct XFeedChannel: ContentChannel {
    let id = "xfeed"
    let displayName = "X"
    let url = URL(string: "https://x.com/home")!

    /// Reading-shaped, not 9:16 video (§8.1: "reading channels get the same
    /// clamp with a ~4:5 ratio").
    let preferredAspect = NSSize(width: 4, height: 5)
    let supportsAutoAdvance = false

    /// A static timeline is already "paused" — nothing plays, nothing moves.
    func pause(in webView: WKWebView) {}

    func attention(in webView: WKWebView) {
        webView.evaluateJavaScript(AttentionBanner.showScript(accent: "#1d9bf0"))
    }
}
