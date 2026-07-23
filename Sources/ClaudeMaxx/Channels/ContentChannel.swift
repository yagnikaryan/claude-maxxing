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
    func userScript() -> WKUserScript      // injected at .atDocumentEnd
    func setAutoAdvance(_ on: Bool, in webView: WKWebView)   // evaluateJavaScript flag flip
    func pause(in webView: WKWebView)              // called before hide
    func attention(in webView: WKWebView)          // channel-appropriate interrupt
}
