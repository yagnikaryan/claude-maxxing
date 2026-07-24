import AppKit
import WebKit

/// Layer 3 content-channel adapter (SPEC §8.1). Channels own all
/// site-specific DOM knowledge; the panel/orchestrator layers only see
/// this protocol. No concrete conformer exists yet — that lands with the
/// first channel adapter (§12 M2 task 8).
protocol ContentChannel {
    var id: String { get }                 // "shorts" | "reading" | "xfeed" | ...
    var displayName: String { get }
    var url: URL { get }
    var preferredAspect: NSSize { get }    // 9:16 video, ~4:5 reading
    var supportsAutoAdvance: Bool { get }
    /// What `FeedPanel` compares to decide whether the webview needs a
    /// (re)load. Defaults to `id` — a feed channel shows one endless stream,
    /// so the channel *is* the content. Channels whose content changes
    /// without the channel changing (ReadingChannel: pick a different
    /// article) fold the selection into this, otherwise switching items
    /// while already on that channel would be a silent no-op.
    var contentIdentity: String { get }
    func userScript() -> WKUserScript      // injected at .atDocumentEnd
    /// How this channel's `url` gets into the webview. Defaults to a plain
    /// web load; overridden where that is wrong (see `ReadingChannel` —
    /// `load(URLRequest:)` refuses `file://` URLs outright).
    func load(into webView: WKWebView)
    func setAutoAdvance(_ on: Bool, in webView: WKWebView)   // evaluateJavaScript flag flip
    func pause(in webView: WKWebView)              // called before hide
    func attention(in webView: WKWebView)          // channel-appropriate interrupt
}

extension ContentChannel {
    var contentIdentity: String { id }

    func load(into webView: WKWebView) {
        webView.load(URLRequest(url: url))
    }

    /// Channels that inject nothing (X hosts the page as-is) still have to
    /// hand `FeedPanel` something to install.
    func userScript() -> WKUserScript {
        WKUserScript(source: "", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// Safe default because it is gated by `supportsAutoAdvance`: a channel
    /// that advertises auto-advance provides the real flip (see
    /// `VideoFeedChannel`), and one that doesn't has nothing to gate.
    func setAutoAdvance(_ on: Bool, in webView: WKWebView) {}
}
