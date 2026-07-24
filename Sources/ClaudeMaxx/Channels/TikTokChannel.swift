import AppKit
import WebKit

/// Layer 3 channel adapter for TikTok's For You feed (SPEC §8.1/§8.2, M4).
///
/// URL confirmed working logged-out (verified against the live site while
/// building this channel). Advancing is scroll-based for the same reason as
/// `ReelsChannel` — the real next-chevron selector must come from inspecting
/// the live desktop DOM, and an attempt to find it hit a
/// narrow-viewport/no-accessible-name variant of the page that never exposed
/// one — and shares `ScrollFeedScript` with it rather than keeping a second
/// copy, which is how this channel came to sit on a broken window-scroll
/// while Reels was fixed.
final class TikTokChannel: ContentChannel {
    let id = "tiktok"
    let displayName = "TikTok"
    let url = URL(string: "https://www.tiktok.com/foryou")!
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

    /// Shared with `ReelsChannel` — same feed shape, same advance mechanics,
    /// including `ShortsChannel`'s `ended` + currentTime watch-complete
    /// detection. See `ScrollFeedScript` for why it is not duplicated here.
    static func scriptSource(channelID: String) -> String {
        ScrollFeedScript.source(channelID: channelID)
    }
}
