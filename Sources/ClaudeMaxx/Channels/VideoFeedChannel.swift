import AppKit
import WebKit

/// Shared behavior for the three vertical video feeds (Shorts, Reels,
/// TikTok). They differ only in id, name, URL, and which of the site's own
/// next-item controls to click — everything else was three byte-identical
/// copies, which is how TikTok sat on a broken window-scroll while Reels was
/// already fixed.
protocol VideoFeedChannel: ContentChannel {
    /// The site's own next-item controls, most specific first. Empty means
    /// scroll-only: §8.2 treats unverified chevron selectors as guesses not
    /// worth trusting, so a channel opts in only once one is read from the
    /// live DOM.
    var nextSelectors: [String] { get }
}

extension VideoFeedChannel {
    var preferredAspect: NSSize { NSSize(width: 9, height: 16) }
    var supportsAutoAdvance: Bool { true }
    var nextSelectors: [String] { [] }

    func userScript() -> WKUserScript {
        WKUserScript(
            source: ScrollFeedScript.source(channelID: id, nextSelectors: nextSelectors),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    /// Native flag flip (§8.2) — no reload, so pause→show on the same channel
    /// keeps the live feed position.
    func setAutoAdvance(_ on: Bool, in webView: WKWebView) {
        webView.evaluateJavaScript("window.__cmAutoAdvance = \(on);")
    }

    /// All videos, not just the first — feed DOMs keep neighboring
    /// (preloading) players around, and any of them can carry audio.
    func pause(in webView: WKWebView) {
        webView.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause());")
    }

    /// §8.4: video channels answer `/attention` by pausing. The unconditional
    /// `.criticalRequest` bounce is FeedPanel's job, not the channel's.
    func attention(in webView: WKWebView) {
        pause(in: webView)
    }
}
