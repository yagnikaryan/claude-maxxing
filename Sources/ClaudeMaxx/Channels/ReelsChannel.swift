import AppKit
import WebKit

/// Layer 3 channel adapter for Instagram Reels (SPEC §8.1/§8.2, M4).
///
/// Advances by scrolling, not by clicking a next-chevron: §8.2 flags those
/// selectors as "unverified guesses by design... not something an agent
/// should trust". `ScrollFeedScript` holds the mechanics — it scrolls the
/// feed's own container (the document does not scroll here), falls back to
/// the window and then a synthetic ArrowDown, and confirms against the
/// on-screen video before reporting an advance.
///
/// Verified against the live logged-in feed: advances land as
/// `container DIV.x1pq812k…` in the daemon log at natural reel spacing.
/// A real chevron selector could still replace the scroll (§12 M4) — the
/// surrounding jitter, `ended` detection, and stats reporting would not
/// need to change.
final class ReelsChannel: ContentChannel {
    let id = "reels"
    let displayName = "Reels"
    let url = URL(string: "https://www.instagram.com/reels/")!
    let preferredAspect = NSSize(width: 9, height: 16)
    let supportsAutoAdvance = true

    func userScript() -> WKUserScript {
        WKUserScript(
            source: Self.scriptSource(channelID: id),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    func setAutoAdvance(_ on: Bool, in webView: WKWebView) {
        webView.evaluateJavaScript("window.__cmAutoAdvance = \(on);")
    }

    func pause(in webView: WKWebView) {
        // All videos, not just the first — feed DOMs keep neighboring
        // (preloading) players around, and any of them can carry audio.
        webView.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause());")
    }

    func attention(in webView: WKWebView) {
        pause(in: webView)
    }

    /// Shared with `TikTokChannel` — same feed shape, same advance mechanics,
    /// including `ShortsChannel`'s `ended` + currentTime watch-complete
    /// detection and the required timing jitter (§8.2). See
    /// `ScrollFeedScript` for why it is not duplicated here.
    static func scriptSource(channelID: String) -> String {
        ScrollFeedScript.source(channelID: channelID)
    }
}
