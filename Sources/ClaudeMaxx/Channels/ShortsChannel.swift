import AppKit
import WebKit

/// Layer 3 channel adapter for YouTube Shorts (SPEC §8.1/§8.2). Highest DOM
/// stability of the three video platforms, so it's the first channel built
/// (§15 decision #10) and the reference implementation the Reels/TikTok
/// adapters will mirror in M4.
final class ShortsChannel: ContentChannel {
    let id = "shorts"
    let displayName = "Shorts"
    let url = URL(string: "https://www.youtube.com/shorts/")!
    let preferredAspect = NSSize(width: 9, height: 16)
    let supportsAutoAdvance = true

    /// Shares `ScrollFeedScript` with Reels and TikTok, passing YouTube's own
    /// next-video controls. Clicking the site's real control is better than
    /// scrolling — it advances exactly one item — and everything around it
    /// (watch-complete detection, timing jitter, the `cm` bridge) is identical
    /// across the three, so it is not worth a second copy of the script. This
    /// channel used to carry one, which is how it kept `querySelector('video')`
    /// (the first video in the DOM, not the one on screen) and missed the
    /// centering, resize handling, and idle diagnostics the others gained.
    func userScript() -> WKUserScript {
        WKUserScript(
            source: ScrollFeedScript.source(
                channelID: id,
                nextSelectors: [
                    "#navigation-button-down button",
                    "button[aria-label=\"Next video\"]",
                ]
            ),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    /// Native-side flag flip (§8.2) — no reload, so pause→show on the same
    /// channel keeps the live feed position.
    func setAutoAdvance(_ on: Bool, in webView: WKWebView) {
        webView.evaluateJavaScript("window.__cmAutoAdvance = \(on);")
    }

    /// Called before hide, and reused by `attention(in:)` (§8.4's "video
    /// channels pause playback" interrupt) — same polite action either way.
    func pause(in webView: WKWebView) {
        // All videos, not just the first — feed DOMs keep neighboring
        // (preloading) players around, and any of them can carry audio.
        webView.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause());")
    }

    /// §8.4: video channels' channel-specific `/attention` behavior is to
    /// pause playback; the unconditional `.criticalRequest` bounce is
    /// FeedPanel's responsibility, not this channel's.
    func attention(in webView: WKWebView) {
        pause(in: webView)
    }
}
