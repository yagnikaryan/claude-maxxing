import AppKit
import WebKit

/// Layer 3 channel adapter for the X (Twitter) home feed (SPEC §8.3).
///
/// Unlike the video channels, XFeed has no watch-complete concept — it is
/// ambient, and deliberately has **no auto-scroll at all**. An earlier build
/// drove a slow continuous scroll (SPEC §8.3's literal 2px/30ms loop, paused
/// on hover); in practice a timeline you read at your own pace has nothing to
/// gain from the page creeping under the pointer, so the loop was removed —
/// the user scrolls, the channel just hosts the page. Per SPEC §8.4,
/// `/attention` overlays a dismissible banner without touching scroll
/// position — yanking text mid-sentence is hostile.
struct XFeedChannel: ContentChannel {
    let id = "xfeed"
    let displayName = "X"
    let url = URL(string: "https://x.com/home")!

    /// Non-video default aspect (SPEC §8.1: "reading channels get the same
    /// clamp with a ~4:5 ratio"). XFeed is a reading-shaped feed, not
    /// 9:16 video, so it shares that ~4:5 ratio rather than
    /// `FeedPanel.defaultAspect`.
    let preferredAspect = NSSize(width: 4, height: 5)

    /// Ambient, not completion-based (SPEC §8.3) — there is no "video
    /// ended" signal to advance on, and no auto-scroll either (see the
    /// type-level comment), so the chip/menu never offers auto-advance
    /// toggling here and `setAutoAdvance` has nothing to gate.
    let supportsAutoAdvance = false

    func userScript() -> WKUserScript {
        WKUserScript(
            source: Self.scriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    func setAutoAdvance(_ on: Bool, in webView: WKWebView) {
        // Protocol requirement only. With the auto-scroll loop gone there is
        // no "auto" behavior left to toggle on this channel.
    }

    func pause(in webView: WKWebView) {
        // Nothing plays and nothing moves on its own — a static timeline is
        // already "paused". Kept as an explicit no-op (protocol requirement).
    }

    func attention(in webView: WKWebView) {
        // SPEC §8.4: reading/X channels overlay a dismissible injected
        // banner *without* touching scroll position. The banner itself is
        // installed by the user script; this just triggers it.
        webView.evaluateJavaScript("window.__cmShowAttentionBanner && window.__cmShowAttentionBanner();")
    }

    // MARK: - Injected JS

    /// Just the dismissible attention banner from §8.4 — no scroll loop; the
    /// timeline moves only when the user moves it (see the type-level
    /// comment). Guarded by `__cmInstalled` like the §8.2 video pattern, so
    /// re-injection on reload is a no-op.
    private static let scriptSource = """
    (function() {
      if (window.__cmInstalled) return;
      window.__cmInstalled = true;

      window.__cmShowAttentionBanner = function() {
        if (document.getElementById('__cm-attention-banner')) return;   // already showing

        var banner = document.createElement('div');
        banner.id = '__cm-attention-banner';
        banner.style.cssText = [
          'position:fixed', 'top:0', 'left:0', 'right:0', 'z-index:2147483647',
          'display:flex', 'align-items:center', 'justify-content:space-between',
          'background:#1d9bf0', 'color:#fff',
          'font:600 13px -apple-system,BlinkMacSystemFont,sans-serif',
          'padding:8px 12px', 'box-shadow:0 2px 6px rgba(0,0,0,0.25)'
        ].join(';');

        var label = document.createElement('span');
        label.textContent = 'Claude needs input';

        var dismiss = document.createElement('button');
        dismiss.textContent = 'Dismiss';
        dismiss.style.cssText = [
          'margin-left:12px', 'background:rgba(255,255,255,0.2)', 'color:#fff',
          'border:none', 'border-radius:4px', 'padding:4px 10px',
          'font:600 12px -apple-system,BlinkMacSystemFont,sans-serif', 'cursor:pointer'
        ].join(';');
        dismiss.addEventListener('click', function() {
          banner.remove();
        });

        banner.appendChild(label);
        banner.appendChild(dismiss);
        // Deliberately does NOT call scrollTo/scrollIntoView — SPEC §8.4:
        // "without touching scroll position".
        document.documentElement.appendChild(banner);
      };
    })();
    """
}
